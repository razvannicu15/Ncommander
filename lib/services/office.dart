// Reads the content of Office files (docx, xlsx, pptx) for the quick view,
// straight from their XML, and the thumbnail Office stores inside them.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// One paragraph of a Word document.
class DocPara {
  const DocPara(this.text, {this.heading = 0, this.bullet = false});
  final String text;

  /// 0 = body text, 1..3 = heading level (title = 1).
  final int heading;
  final bool bullet;
}

class Sheet {
  Sheet(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

class Slide {
  Slide(this.paragraphs);
  final List<String> paragraphs;
}

/// What the quick view shows; exactly one list is filled.
class OfficeContent {
  OfficeContent({this.paras = const [], this.sheets = const [], this.slides = const []});
  final List<DocPara> paras;
  final List<Sheet> sheets;
  final List<Slide> slides;
}

const officeExts = {'docx', 'xlsx', 'pptx', 'docm', 'xlsm', 'pptm'};

Future<OfficeContent> readOffice(String path) => Isolate.run(() => _read(path));

String _xmlText(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16)))
    .replaceAll('&amp;', '&');

OfficeContent _read(String path) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    String? xml(String name) {
      final f = zip.findFile(name);
      final b = f?.readBytes();
      return b == null ? null : utf8.decode(b, allowMalformed: true);
    }

    final ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
    if (ext.startsWith('doc')) return OfficeContent(paras: _docx(xml('word/document.xml') ?? ''));
    if (ext.startsWith('xls')) return OfficeContent(sheets: _xlsx(xml));
    return OfficeContent(slides: _pptx(zip, xml));
  } finally {
    input.closeSync();
  }
}

final _wText = RegExp(r'<w:t(?:\s[^>]*)?>(.*?)</w:t>', dotAll: true);

List<DocPara> _docx(String doc) {
  final out = <DocPara>[];
  for (final m in RegExp(r'<w:p[ >].*?</w:p>', dotAll: true).allMatches(doc)) {
    final p = m[0]!;
    final text = _xmlText(p
        .replaceAll(RegExp(r'<w:tab\s*/>'), '\t')
        .replaceAll(RegExp(r'<w:br\s*/>'), '\n')
        .let((x) => _wText.allMatches(x).map((t) => t[1]!).join()));
    final style = RegExp(r'<w:pStyle w:val="([^"]+)"').firstMatch(p)?[1]?.toLowerCase() ?? '';
    var h = 0;
    if (style.contains('title') || style.contains('titlu') && !style.contains(RegExp(r'\d'))) {
      h = 1;
    } else {
      final n = RegExp(r'(?:heading|titlu)\s*(\d)').firstMatch(style)?[1];
      if (n != null) h = int.parse(n).clamp(1, 3);
    }
    out.add(DocPara(text, heading: h, bullet: p.contains('<w:numPr>')));
  }
  // Drop runs of empty paragraphs.
  final clean = <DocPara>[];
  for (final p in out) {
    if (p.text.trim().isEmpty && (clean.isEmpty || clean.last.text.trim().isEmpty)) continue;
    clean.add(p);
  }
  return clean;
}

int _col(String ref) {
  var n = 0;
  for (final c in ref.codeUnits) {
    if (c < 65 || c > 90) break;
    n = n * 26 + (c - 64);
  }
  return n - 1;
}

List<Sheet> _xlsx(String? Function(String) xml) {
  final shared = <String>[
    for (final si in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(xml('xl/sharedStrings.xml') ?? ''))
      _xmlText(RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true).allMatches(si[1]!).map((t) => t[1]!).join()),
  ];
  final rels = <String, String>{
    for (final r in RegExp(r'<Relationship [^>]*?Id="([^"]+)"[^>]*?Target="([^"]+)"').allMatches(xml('xl/_rels/workbook.xml.rels') ?? ''))
      r[1]!: r[2]!,
  };
  // Some writers put Target before Id.
  for (final r in RegExp(r'<Relationship [^>]*?Target="([^"]+)"[^>]*?Id="([^"]+)"').allMatches(xml('xl/_rels/workbook.xml.rels') ?? '')) {
    rels[r[2]!] = r[1]!;
  }
  final sheets = <Sheet>[];
  for (final s in RegExp(r'<sheet [^>]*?name="([^"]+)"[^>]*?r:id="([^"]+)"').allMatches(xml('xl/workbook.xml') ?? '')) {
    var target = rels[s[2]!] ?? '';
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    final body = xml(target) ?? '';
    final rows = <List<String>>[];
    for (final row in RegExp(r'<row[^>]*?(?:/>|>(.*?)</row>)', dotAll: true).allMatches(body)) {
      if (rows.length >= 500) break;
      final cells = <String>[];
      for (final c in RegExp(r'<c ([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true).allMatches(row[1] ?? '')) {
        final attrs = c[1]!;
        final idx = _col(RegExp(r'r="([A-Z]+)').firstMatch(attrs)?[1] ?? '');
        final type = RegExp(r't="([^"]+)"').firstMatch(attrs)?[1];
        final inner = c[2] ?? '';
        final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner)?[1];
        var text = switch (type) {
          's' => v == null ? '' : (shared.elementAtOrNull(int.tryParse(v) ?? -1) ?? ''),
          'inlineStr' => RegExp(r'<t(?:\s[^>]*)?>(.*?)</t>', dotAll: true).allMatches(inner).map((t) => t[1]!).join(),
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          _ => v ?? '',
        };
        text = _xmlText(text);
        // Tidy numbers like 0.30000000000000004.
        final d = type == null ? double.tryParse(text) : null;
        if (d != null && text.length > 12) text = d.toStringAsPrecision(10).replaceFirst(RegExp(r'\.?0+$'), '');
        if (idx >= 0 && idx < 60) {
          while (cells.length < idx) {
            cells.add('');
          }
          if (cells.length == idx) cells.add(text);
        }
      }
      rows.add(cells);
    }
    while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
      rows.removeLast();
    }
    sheets.add(Sheet(_xmlText(s[1]!), rows));
  }
  return sheets;
}

List<Slide> _pptx(Archive zip, String? Function(String) xml) {
  final names = zip.files.map((f) => f.name).where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n)).toList()
    ..sort((a, b) => int.parse(RegExp(r'(\d+)\.xml').firstMatch(a)![1]!).compareTo(int.parse(RegExp(r'(\d+)\.xml').firstMatch(b)![1]!)));
  return [
    for (final n in names)
      Slide([
        for (final p in RegExp(r'<a:p>(.*?)</a:p>', dotAll: true).allMatches(xml(n) ?? ''))
          _xmlText(RegExp(r'<a:t>(.*?)</a:t>', dotAll: true).allMatches(p[1]!).map((t) => t[1]!).join()),
      ].where((t) => t.trim().isNotEmpty).toList()),
  ];
}

/// The preview picture Office saves in docProps (always for PowerPoint,
/// when "Save thumbnail" is on for Word/Excel). Null when there is none.
Future<Uint8List?> officeThumb(String path) => Isolate.run(() {
      final input = InputFileStream(path);
      try {
        final zip = ZipDecoder().decodeStream(input);
        for (final f in zip.files) {
          final n = f.name.toLowerCase();
          if (n.startsWith('docprops/thumbnail.') && (n.endsWith('.jpeg') || n.endsWith('.jpg') || n.endsWith('.png'))) {
            return f.readBytes();
          }
        }
      } catch (_) {
      } finally {
        input.closeSync();
      }
      return null;
    });

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
