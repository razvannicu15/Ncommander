// Reads docx / pptx into a layout model close to the original: runs with
// fonts and colours, paragraph alignment and spacing, tables, pictures,
// page / slide size. Rendered by ui/office_view.dart.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'xml_lite.dart';

const _emuPerPx = 9525.0; // 914400 EMU per inch, 96 px per inch

class Run {
  Run(this.text, {this.bold = false, this.italic = false, this.underline = false, this.strike = false, this.size, this.color, this.font, this.highlight});
  final String text;
  final bool bold, italic, underline, strike;

  /// Points.
  final double? size;
  final int? color, highlight;
  final String? font;
}

class Pic {
  Pic(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final double width, height; // px
}

/// A paragraph (text and inline pictures).
class Para {
  Para({
    this.runs = const [],
    this.pics = const [],
    this.align = 'left',
    this.before = 0,
    this.after = 6,
    this.indent = 0,
    this.firstLine = 0,
    this.lineHeight = 1.15,
    this.bullet,
    this.pageBreakBefore = false,
  });
  final List<Run> runs;
  final List<Pic> pics;
  final String align; // left, center, right, both
  final double before, after, indent, firstLine; // pt
  final double lineHeight;
  final String? bullet;
  final bool pageBreakBefore;

  bool get isEmpty => runs.every((r) => r.text.trim().isEmpty) && pics.isEmpty;
}

class Table {
  Table(this.rows, this.widths);
  final List<List<List<Para>>> rows; // row -> cell -> paragraphs
  final List<double> widths; // px, may be empty
}

class WordDoc {
  WordDoc({required this.blocks, required this.pageW, required this.pageH, required this.margin, required this.defaultSize, required this.defaultFont});
  final List<Object> blocks; // Para | Table
  final double pageW, pageH; // px
  final List<double> margin; // top, right, bottom, left px
  final double defaultSize; // pt
  final String? defaultFont;
}

// ------------------------------------------------------------------ docx

Future<WordDoc> readDocx(String path) => Isolate.run(() => _docx(path));

int? _hex(String? v) {
  if (v == null || v == 'auto' || v.length != 6) return null;
  final n = int.tryParse(v, radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

const _highlights = {
  'yellow': 0xFFFFFF00, 'green': 0xFF00FF00, 'cyan': 0xFF00FFFF, 'magenta': 0xFFFF00FF, 'blue': 0xFF0000FF,
  'red': 0xFFFF0000, 'darkBlue': 0xFF000080, 'darkCyan': 0xFF008080, 'darkGreen': 0xFF008000, 'darkMagenta': 0xFF800080,
  'darkRed': 0xFF800000, 'darkYellow': 0xFF808000, 'darkGray': 0xFF808080, 'lightGray': 0xFFC0C0C0, 'black': 0xFF000000,
};

bool _on(XNode? n) => n != null && n['w:val'] != '0' && n['w:val'] != 'false' && n['w:val'] != 'none';

class _Style {
  bool? b, i, u;
  double? size;
  int? color;
  String? font, align;
  double? before, after;
  int heading = 0;
  String? basedOn;
}

WordDoc _docx(String path) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    String text(String n) {
      final b = zip.findFile(n)?.readBytes();
      return b == null ? '' : utf8.decode(b, allowMalformed: true);
    }

    // Relationships -> media.
    final rels = <String, String>{};
    for (final r in parseXml(text('word/_rels/document.xml.rels')).findAll('Relationship')) {
      rels[r['Id'] ?? ''] = r['Target'] ?? '';
    }
    Uint8List? media(String id) {
      final t = rels[id];
      if (t == null) return null;
      final p = t.startsWith('/') ? t.substring(1) : 'word/${t.replaceFirst(RegExp(r'^\./'), '')}';
      return zip.findFile(p)?.readBytes();
    }

    // Styles: paragraph defaults and headings.
    final styles = <String, _Style>{};
    double defSize = 11;
    String? defFont;
    final sx = parseXml(text('word/styles.xml'));
    final dd = sx.find('w:docDefaults');
    final dsz = dd?.find('w:sz')?['w:val'];
    if (dsz != null) defSize = (int.tryParse(dsz) ?? 22) / 2;
    defFont = dd?.find('w:rFonts')?['w:ascii'];
    for (final st in sx.findAll('w:style')) {
      final s = _Style();
      final id = st['w:styleId'] ?? '';
      final name = (st.child('w:name')?['w:val'] ?? id).toLowerCase();
      final m = RegExp(r'(?:heading|titlu)\s*(\d)').firstMatch(name);
      if (m != null) s.heading = int.parse(m[1]!);
      if (name == 'title' || name == 'titlu') s.heading = 1;
      s.basedOn = st.child('w:basedOn')?['w:val'];
      final rpr = st.child('w:rPr');
      if (rpr != null) {
        if (rpr.child('w:b') != null) s.b = _on(rpr.child('w:b'));
        if (rpr.child('w:i') != null) s.i = _on(rpr.child('w:i'));
        if (rpr.child('w:u') != null) s.u = _on(rpr.child('w:u'));
        final sz = rpr.child('w:sz')?['w:val'];
        if (sz != null) s.size = (int.tryParse(sz) ?? 22) / 2;
        s.color = _hex(rpr.child('w:color')?['w:val']);
        s.font = rpr.child('w:rFonts')?['w:ascii'];
      }
      final ppr = st.child('w:pPr');
      if (ppr != null) {
        s.align = ppr.child('w:jc')?['w:val'];
        final sp = ppr.child('w:spacing');
        if (sp?['w:before'] != null) s.before = (int.tryParse(sp!['w:before']!) ?? 0) / 20;
        if (sp?['w:after'] != null) s.after = (int.tryParse(sp!['w:after']!) ?? 0) / 20;
      }
      styles[id] = s;
    }
    T? styled<T>(String? id, T? Function(_Style) f) {
      var cur = id;
      for (var guard = 0; cur != null && guard < 10; guard++) {
        final s = styles[cur];
        if (s == null) return null;
        final v = f(s);
        if (v != null) return v;
        cur = s.basedOn;
      }
      return null;
    }

    final doc = parseXml(text('word/document.xml'));
    final body = doc.find('w:body');

    Para para(XNode p, {bool inTable = false}) {
      final ppr = p.child('w:pPr');
      final sid = ppr?.child('w:pStyle')?['w:val'];
      final runs = <Run>[];
      final pics = <Pic>[];
      var breakBefore = ppr?.child('w:pageBreakBefore') != null;
      void run(XNode r) {
        final rpr = r.child('w:rPr');
        final rsid = rpr?.child('w:rStyle')?['w:val'];
        bool flag(String tag, bool? Function(_Style) st) {
          final n = rpr?.child(tag);
          if (n != null) return _on(n);
          return styled(rsid, st) ?? styled(sid, st) ?? false;
        }

        final sz = rpr?.child('w:sz')?['w:val'];
        final size = sz != null ? (int.tryParse(sz) ?? 22) / 2 : (styled(rsid, (s) => s.size) ?? styled(sid, (s) => s.size));
        final color = _hex(rpr?.child('w:color')?['w:val']) ?? styled(rsid, (s) => s.color) ?? styled(sid, (s) => s.color);
        final font = rpr?.child('w:rFonts')?['w:ascii'] ?? styled(sid, (s) => s.font);
        final hl = _highlights[rpr?.child('w:highlight')?['w:val']] ?? _hex(rpr?.child('w:shd')?['w:fill']);
        final b = StringBuffer();
        for (final c in r.children) {
          switch (c.name) {
            case 'w:t':
              b.write(c.innerText);
            case 'w:tab':
              b.write('\t');
            case 'w:br':
              if (c['w:type'] == 'page') {
                // A page break inside a paragraph: rest goes on a new page.
                breakBefore = breakBefore || runs.isEmpty && b.isEmpty;
              } else {
                b.write('\n');
              }
            case 'w:drawing':
            case 'w:pict':
              final blip = c.find('a:blip');
              final id = blip?['r:embed'] ?? c.find('v:imagedata')?['r:id'];
              final bytes = id == null ? null : media(id);
              if (bytes != null) {
                final ext = c.find('wp:extent');
                final w = double.tryParse(ext?['cx'] ?? '') ?? 0, h = double.tryParse(ext?['cy'] ?? '') ?? 0;
                pics.add(Pic(bytes, w > 0 ? w / _emuPerPx : 300, h > 0 ? h / _emuPerPx : 200));
              }
          }
        }
        if (b.isNotEmpty) {
          runs.add(Run(
            b.toString(),
            bold: flag('w:b', (s) => s.b),
            italic: flag('w:i', (s) => s.i),
            underline: flag('w:u', (s) => s.u),
            strike: _on(rpr?.child('w:strike')),
            size: size,
            color: color,
            font: font,
            highlight: hl,
          ));
        }
      }

      for (final c in p.children) {
        if (c.name == 'w:r') {
          run(c);
        } else if (c.name == 'w:hyperlink' || c.name == 'w:smartTag' || c.name == 'w:ins' || c.name == 'w:fldSimple' || c.name == 'w:sdt') {
          for (final r in c.findAll('w:r')) {
            run(r);
          }
        }
      }
      final sp = ppr?.child('w:spacing');
      final ind = ppr?.child('w:ind');
      final line = int.tryParse(sp?['w:line'] ?? '');
      final num = ppr?.child('w:numPr');
      return Para(
        runs: runs,
        pics: pics,
        align: ppr?.child('w:jc')?['w:val'] ?? styled(sid, (s) => s.align) ?? 'left',
        before: sp?['w:before'] != null ? (int.tryParse(sp!['w:before']!) ?? 0) / 20 : (styled(sid, (s) => s.before) ?? 0),
        after: sp?['w:after'] != null ? (int.tryParse(sp!['w:after']!) ?? 0) / 20 : (styled(sid, (s) => s.after) ?? (inTable ? 0 : 8)),
        indent: (int.tryParse(ind?['w:left'] ?? ind?['w:start'] ?? '') ?? 0) / 20,
        firstLine: ((int.tryParse(ind?['w:firstLine'] ?? '') ?? 0) - (int.tryParse(ind?['w:hanging'] ?? '') ?? 0)) / 20,
        lineHeight: line != null && (sp?['w:lineRule'] ?? 'auto') == 'auto' ? (line / 240 * 1.15).clamp(0.9, 3.0) : 1.15,
        bullet: num != null ? '•' : null,
        pageBreakBefore: breakBefore,
      );
    }

    Table table(XNode t) {
      final widths = [for (final g in t.find('w:tblGrid')?.all('w:gridCol') ?? const <XNode>[]) (int.tryParse(g['w:w'] ?? '') ?? 0) / 15.0];
      final rows = <List<List<Para>>>[];
      for (final tr in t.all('w:tr')) {
        rows.add([
          for (final tc in tr.all('w:tc')) [for (final p in tc.all('w:p')) para(p, inTable: true)],
        ]);
      }
      return Table(rows, widths);
    }

    final blocks = <Object>[];
    for (final c in body?.children ?? const <XNode>[]) {
      if (c.name == 'w:p') {
        blocks.add(para(c));
      } else if (c.name == 'w:tbl') {
        blocks.add(table(c));
      } else if (c.name == 'w:sdt') {
        for (final p in c.findAll('w:p')) {
          blocks.add(para(p));
        }
      }
    }

    final sect = body?.child('w:sectPr');
    final pg = sect?.child('w:pgSz');
    final mar = sect?.child('w:pgMar');
    double tw(String? v, double d) => v == null ? d : (int.tryParse(v) ?? (d * 15)) / 15;
    return WordDoc(
      blocks: blocks,
      pageW: tw(pg?['w:w'], 794),
      pageH: tw(pg?['w:h'], 1123),
      margin: [tw(mar?['w:top'], 96), tw(mar?['w:right'], 96), tw(mar?['w:bottom'], 96), tw(mar?['w:left'], 96)],
      defaultSize: defSize,
      defaultFont: defFont,
    );
  } finally {
    input.closeSync();
  }
}

// ------------------------------------------------------------------ pptx

class Shape {
  Shape({required this.x, required this.y, required this.w, required this.h, this.fill, this.line, this.paras = const [], this.pic, this.anchor = 't', this.round = false});
  final double x, y, w, h; // px
  final int? fill, line;
  final List<Para> paras;
  final Uint8List? pic;
  final String anchor; // t, ctr, b
  final bool round;
}

class SlideX {
  SlideX(this.shapes, {this.background, this.bgPic});
  final List<Shape> shapes;
  final int? background;
  final Uint8List? bgPic;
}

class Deck {
  Deck(this.slides, this.width, this.height);
  final List<SlideX> slides;
  final double width, height; // px
}

Future<Deck> readPptx(String path) => Isolate.run(() => _pptx(path));

Deck _pptx(String path) {
  final input = InputFileStream(path);
  try {
    final zip = ZipDecoder().decodeStream(input);
    String text(String n) {
      final b = zip.findFile(n)?.readBytes();
      return b == null ? '' : utf8.decode(b, allowMalformed: true);
    }

    String resolve(String base, String target) {
      if (target.startsWith('/')) return target.substring(1);
      final parts = base.split('/')..removeLast();
      for (final seg in target.split('/')) {
        if (seg == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else if (seg != '.') {
          parts.add(seg);
        }
      }
      return parts.join('/');
    }

    Map<String, String> relsOf(String part) {
      final dir = part.substring(0, part.lastIndexOf('/'));
      final name = part.substring(part.lastIndexOf('/') + 1);
      return {
        for (final r in parseXml(text('$dir/_rels/$name.rels')).findAll('Relationship'))
          r['Id'] ?? '': resolve(part, r['Target'] ?? ''),
      };
    }

    // Theme colours for schemeClr.
    final theme = <String, int>{};
    final themePart = zip.files.map((f) => f.name).where((n) => RegExp(r'^ppt/theme/theme\d+\.xml$').hasMatch(n)).firstOrNull;
    if (themePart != null) {
      final cs = parseXml(text(themePart)).find('a:clrScheme');
      for (final c in cs?.children ?? const <XNode>[]) {
        if (c.isText) continue;
        final v = c.find('a:srgbClr')?['val'] ?? c.find('a:sysClr')?['lastClr'];
        final h = _hex(v);
        if (h != null) theme[c.name.replaceFirst('a:', '')] = h;
      }
      theme['tx1'] = theme['dk1'] ?? 0xFF000000;
      theme['bg1'] = theme['lt1'] ?? 0xFFFFFFFF;
      theme['tx2'] = theme['dk2'] ?? 0xFF333333;
      theme['bg2'] = theme['lt2'] ?? 0xFFEEEEEE;
    }
    int? color(XNode? fillParent) {
      final s = fillParent?.child('a:solidFill') ?? (fillParent?.name == 'a:solidFill' ? fillParent : null);
      if (s == null) return null;
      final rgb = s.child('a:srgbClr')?['val'];
      if (rgb != null) return _hex(rgb);
      final sch = s.child('a:schemeClr')?['val'];
      if (sch != null) return theme[sch];
      return _hex(s.child('a:sysClr')?['lastClr']);
    }

    final pres = parseXml(text('ppt/presentation.xml'));
    final sz = pres.find('p:sldSz');
    final width = (double.tryParse(sz?['cx'] ?? '') ?? 12192000) / _emuPerPx;
    final height = (double.tryParse(sz?['cy'] ?? '') ?? 6858000) / _emuPerPx;
    final presRels = relsOf('ppt/presentation.xml');
    final order = [for (final s in pres.findAll('p:sldId')) presRels[s['r:id']] ?? ''].where((s) => s.isNotEmpty).toList();

    // Placeholder positions from layout / master (title, body…).
    Map<String, XNode> placeholders(String part) {
      final out = <String, XNode>{};
      for (final sp in parseXml(text(part)).findAll('p:sp')) {
        final ph = sp.find('p:ph');
        if (ph == null || sp.find('a:xfrm') == null) continue;
        out['t:${ph['type'] ?? 'body'}'] ??= sp;
        if (ph['idx'] != null) out['i:${ph['idx']}'] ??= sp;
      }
      return out;
    }

    List<Para> paras(XNode? tx, {double defSize = 18, int? defColor}) {
      final out = <Para>[];
      for (final p in tx?.all('a:p') ?? const <XNode>[]) {
        final ppr = p.child('a:pPr');
        final runs = <Run>[];
        for (final r in p.children) {
          if (r.name != 'a:r' && r.name != 'a:fld' && r.name != 'a:br') continue;
          if (r.name == 'a:br') {
            runs.add(Run('\n'));
            continue;
          }
          final rpr = r.child('a:rPr');
          final s = double.tryParse(rpr?['sz'] ?? '');
          runs.add(Run(
            r.child('a:t')?.innerText ?? '',
            bold: rpr?['b'] == '1',
            italic: rpr?['i'] == '1',
            underline: (rpr?['u'] ?? 'none') != 'none',
            size: s != null ? s / 100 : defSize,
            color: color(rpr) ?? defColor,
            font: rpr?.child('a:latin')?['typeface'],
          ));
        }
        final algn = ppr?['algn'];
        out.add(Para(
          runs: runs,
          align: switch (algn) { 'ctr' => 'center', 'r' => 'right', 'just' => 'both', _ => 'left' },
          after: 4,
          bullet: ppr?.child('a:buChar')?['char'] ?? (ppr?.child('a:buAutoNum') != null ? '•' : null),
          indent: (double.tryParse(ppr?['marL'] ?? '') ?? 0) / _emuPerPx * 0.75,
        ));
      }
      return out;
    }

    (double, double, double, double)? xfrm(XNode? sp) {
      final x = sp?.find('a:xfrm');
      final off = x?.child('a:off'), ext = x?.child('a:ext');
      if (off == null || ext == null) return null;
      double v(XNode n, String a) => (double.tryParse(n[a] ?? '') ?? 0) / _emuPerPx;
      return (v(off, 'x'), v(off, 'y'), v(ext, 'cx'), v(ext, 'cy'));
    }

    final slides = <SlideX>[];
    for (final part in order) {
      final rels = relsOf(part);
      final layoutPart = rels.values.firstWhere((t) => t.contains('slideLayouts/'), orElse: () => '');
      final layoutPh = layoutPart.isEmpty ? <String, XNode>{} : placeholders(layoutPart);
      final masterPart = layoutPart.isEmpty ? '' : relsOf(layoutPart).values.firstWhere((t) => t.contains('slideMasters/'), orElse: () => '');
      final masterPh = masterPart.isEmpty ? <String, XNode>{} : placeholders(masterPart);
      final x = parseXml(text(part));

      int? bg;
      Uint8List? bgPic;
      XNode? bgNode = x.find('p:bg');
      if (bgNode == null && layoutPart.isNotEmpty) bgNode = parseXml(text(layoutPart)).find('p:bg');
      if (bgNode == null && masterPart.isNotEmpty) bgNode = parseXml(text(masterPart)).find('p:bg');
      if (bgNode != null) {
        final bgPr = bgNode.child('p:bgPr');
        bg = color(bgPr);
        final ref = bgNode.child('p:bgRef');
        if (bg == null && ref != null) bg = theme[ref.child('a:schemeClr')?['val']];
        final blip = bgPr?.find('a:blip')?['r:embed'];
        if (blip != null) bgPic = zip.findFile(rels[blip] ?? '')?.readBytes();
      }

      final shapes = <Shape>[];
      for (final el in x.find('p:spTree')?.children ?? const <XNode>[]) {
        void add(XNode sp) {
          if (sp.name == 'p:grpSp') {
            for (final c in sp.children) {
              add(c);
            }
            return;
          }
          if (sp.name == 'p:sp') {
            final ph = sp.find('p:ph');
            final key1 = ph?['idx'] != null ? 'i:${ph!['idx']}' : null;
            final key2 = 't:${ph?['type'] ?? 'body'}';
            var box = xfrm(sp);
            if (box == null && ph != null) {
              box = xfrm(layoutPh[key1] ?? layoutPh[key2] ?? masterPh[key2] ?? masterPh[key1]);
            }
            if (box == null) return;
            final title = ph != null && (ph['type'] == 'title' || ph['type'] == 'ctrTitle');
            final spPr = sp.child('p:spPr');
            final txt = sp.child('p:txBody');
            final ps = paras(txt, defSize: title ? 40 : (ph != null ? 22 : 18), defColor: theme['tx1']);
            final anchor = txt?.child('a:bodyPr')?['anchor'] ?? (title ? 'ctr' : 't');
            final geom = spPr?.child('a:prstGeom')?['prst'];
            shapes.add(Shape(
              x: box.$1, y: box.$2, w: box.$3, h: box.$4,
              fill: color(spPr),
              line: color(spPr?.child('a:ln')),
              paras: ps,
              anchor: anchor,
              round: geom == 'roundRect' || geom == 'ellipse',
            ));
          } else if (sp.name == 'p:pic') {
            final box = xfrm(sp);
            final id = sp.find('a:blip')?['r:embed'];
            final bytes = id == null ? null : zip.findFile(rels[id] ?? '')?.readBytes();
            if (box != null && bytes != null) {
              shapes.add(Shape(x: box.$1, y: box.$2, w: box.$3, h: box.$4, pic: bytes));
            }
          }
        }

        add(el);
      }
      slides.add(SlideX(shapes, background: bg, bgPic: bgPic));
    }
    return Deck(slides, width, height);
  } finally {
    input.closeSync();
  }
}
