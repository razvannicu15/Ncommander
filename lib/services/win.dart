// Windows side of the native bridge: drives, free space, opening files,
// the system accent colour. Only called when Platform.isWindows.
import 'dart:ffi';
import 'dart:io';

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
