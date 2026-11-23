// Windows side of the native bridge: drives, free space, opening files,
// the system accent colour. Only called when Platform.isWindows.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

final _k32 = DynamicLibrary.open('kernel32.dll');

final _getLogicalDrives = _k32.lookupFunction<Uint32 Function(), int Function()>('GetLogicalDrives');
final _getDriveType = _k32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetDriveTypeW');
final _getVolumeInfo = _k32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>, Uint32),
    int Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>, int)>('GetVolumeInformationW');
final _getFreeSpace = _k32.lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
    int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetDiskFreeSpaceExW');

final _getAttrs = _k32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetFileAttributesW');

/// Hidden or system file (AppData, desktop.ini, junctions like "Application Data").
bool winHidden(String path) {
  final p = winPath(path).toNativeUtf16();
  try {
    final a = _getAttrs(p);
    return a != 0xFFFFFFFF && a & 0x6 != 0;
  } finally {
    calloc.free(p);
  }
}

const _removable = 2, _fixed = 3, _remote = 4;

/// "C:/Users/x" -> "C:\Users\x" for Windows tools.
String winPath(String p) => p.replaceAll('/', r'\');

String driveOf(String path) => path.length >= 2 && path[1] == ':' ? '${path.substring(0, 2).toUpperCase()}/' : 'C:/';

List<Volume> winVolumes() {
  final out = <Volume>[];
  final mask = _getLogicalDrives();
  for (var i = 0; i < 26; i++) {
    if (mask & (1 << i) == 0) continue;
    final letter = String.fromCharCode(65 + i);
    final root = '$letter:\\'.toNativeUtf16();
    final name = calloc<Uint16>(261).cast<Utf16>();
    try {
      final type = _getDriveType(root);
      if (type != _removable && type != _fixed && type != _remote) continue;
      // Not ready (empty card reader): skip.
      if (_getVolumeInfo(root, name, 261, nullptr, nullptr, nullptr, nullptr, 0) == 0) continue;
      final (total, free) = winSpace('$letter:/');
      out.add(Volume(
        path: '$letter:/',
        label: name.toDartString(),
        removable: type == _removable,
        network: type == _remote,
        primary: letter == 'C',
        total: total,
        free: free,
      ));
    } finally {
      calloc.free(root);
      calloc.free(name);
    }
  }
  return out;
}

(int, int) winSpace(String path) {
  final root = winPath(driveOf(path)).toNativeUtf16();
  final avail = calloc<Uint64>(), total = calloc<Uint64>(), free = calloc<Uint64>();
  try {
    if (_getFreeSpace(root, avail, total, free) == 0) return (0, 0);
    return (total.value, avail.value);
  } finally {
    calloc.free(root);
    calloc.free(avail);
    calloc.free(total);
    calloc.free(free);
  }
}

/// Default app, or Windows' "Open with" chooser.
Future<bool> winOpen(String path, {bool chooser = false}) async {
  try {
    if (chooser) {
      await Process.start('rundll32.exe', ['shell32.dll,OpenAs_RunDLL', winPath(path)]);
    } else {
      await Process.start('explorer.exe', [winPath(path)]);
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> winOpenUrl(String url) async {
  try {
    await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
  } catch (_) {}
}

/// Windows accent colour (DWM, stored as ABGR).
Future<int?> winAccent() async {
  try {
    final r = await Process.run('reg', ['query', r'HKCU\Software\Microsoft\Windows\DWM', '/v', 'AccentColor']);
    final m = RegExp(r'0x([0-9a-fA-F]+)').firstMatch('${r.stdout}');
    if (m == null) return null;
    final abgr = int.parse(m.group(1)!, radix: 16);
    final b = (abgr >> 16) & 0xFF, g = (abgr >> 8) & 0xFF, r0 = abgr & 0xFF;
    return 0xFF000000 | (r0 << 16) | (g << 8) | b;
  } catch (_) {
    return null;
  }
}

/// The user's folders, for the Locations drawer.
String get winHome => (Platform.environment['USERPROFILE'] ?? 'C:/Users').replaceAll(r'\', '/');

/// Exact preview of Office files on Windows: Word / Excel / PowerPoint (or
/// LibreOffice) print them to a PDF once; the copy is reused until the file
/// changes. Null when neither is installed or the export fails.
Future<String?> officeToPdf(String path) async {
  try {
    final st = File(path).statSync();
    final dir = Directory('${Directory.systemTemp.path}\\ncommander_preview')..createSync(recursive: true);
    final key = '${path.hashCode.toUnsigned(32).toRadixString(36)}_${st.modified.millisecondsSinceEpoch}_${st.size}';
    final out = '${dir.path}\\$key.pdf';
    if (File(out).existsSync() && File(out).lengthSync() > 0) return out;
    final src = winPath(path);
    String q(String s) => s.replaceAll("'", "''");
    final ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
    final script = switch (ext) {
      'doc' || 'docx' || 'docm' || 'rtf' || 'odt' || 'dot' || 'dotx' =>
        "\$a=New-Object -ComObject Word.Application;\$a.Visible=\$false;\$a.DisplayAlerts=0;\$d=\$a.Documents.Open('${q(src)}',\$false,\$true,\$false);\$d.ExportAsFixedFormat('${q(out)}',17);\$d.Close(0);\$a.Quit()",
      'xls' || 'xlsx' || 'xlsm' || 'ods' || 'csv' =>
        "\$a=New-Object -ComObject Excel.Application;\$a.Visible=\$false;\$a.DisplayAlerts=\$false;\$w=\$a.Workbooks.Open('${q(src)}',0,\$true);\$w.ExportAsFixedFormat(0,'${q(out)}');\$w.Close(\$false);\$a.Quit()",
      _ =>
        "\$a=New-Object -ComObject PowerPoint.Application;\$p=\$a.Presentations.Open('${q(src)}',\$true,\$false,\$false);\$p.SaveAs('${q(out)}',32);\$p.Close();\$a.Quit()",
    };
    final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script])
        .timeout(const Duration(seconds: 90));
    if (r.exitCode == 0 && File(out).existsSync()) return out;
    // LibreOffice, if installed.
    for (final soffice in [r'C:\Program Files\LibreOffice\program\soffice.exe', r'C:\Program Files (x86)\LibreOffice\program\soffice.exe']) {
      if (!File(soffice).existsSync()) continue;
      final tmp = Directory('${dir.path}\\lo_$key')..createSync(recursive: true);
      await Process.run(soffice, ['--headless', '--convert-to', 'pdf', '--outdir', tmp.path, src]).timeout(const Duration(seconds: 90));
      final made = tmp.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.pdf')).firstOrNull;
      if (made != null) {
        made.renameSync(out);
        return out;
      }
    }
  } catch (_) {}
  return null;
}

// ------------------------------------------------------------------ DPAPI

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

final _crypt32 = DynamicLibrary.open('crypt32.dll');
typedef _DpapiN = Int32 Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _DpapiD = int Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _UnprotN = Int32 Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _UnprotD = int Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
final _protect = _crypt32.lookupFunction<_DpapiN, _DpapiD>('CryptProtectData');
final _unprotect = _crypt32.lookupFunction<_UnprotN, _UnprotD>('CryptUnprotectData');
final _localFree = _k32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

/// Windows DPAPI: data only this Windows user, on this PC, can decrypt.
Uint8List? dpapi(Uint8List data, {required bool protect}) {
  final input = calloc<_Blob>(), output = calloc<_Blob>();
  final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
  try {
    buf.asTypedList(data.length).setAll(0, data);
    input.ref
      ..cbData = data.length
      ..pbData = buf;
    const uiForbidden = 0x1;
    final ok = protect
        ? _protect(input, nullptr, nullptr, nullptr, nullptr, uiForbidden, output)
        : _unprotect(input, nullptr, nullptr, nullptr, nullptr, uiForbidden, output);
    if (ok == 0) return null;
    final out = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
    _localFree(output.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(buf);
    calloc.free(input);
    calloc.free(output);
  }
}
