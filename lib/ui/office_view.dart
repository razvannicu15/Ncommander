import 'dart:math' as math;

import 'package:flutter/material.dart' hide Table, TableRow;
import 'package:flutter/material.dart' as m show Table, TableRow, TableBorder, FixedColumnWidth, FlexColumnWidth, TableColumnWidth, TableCellVerticalAlignment;

import '../services/office_layout.dart';

const _pt = 96 / 72; // points -> logical pixels

TextSpan _span(List<Run> runs, double defSize, String? defFont, {double scale = 1, int? defColor}) => TextSpan(children: [
      for (final r in runs)
        TextSpan(
          text: r.text,
          style: TextStyle(
            fontSize: (r.size ?? defSize) * _pt * scale,
            fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
            decoration: TextDecoration.combine([if (r.underline) TextDecoration.underline, if (r.strike) TextDecoration.lineThrough]),
            color: Color(r.color ?? defColor ?? 0xFF000000),
            backgroundColor: r.highlight == null ? null : Color(r.highlight!),
            fontFamily: r.font ?? defFont,
          ),
        ),
    ]);

TextAlign _align(String a) => switch (a) { 'center' => TextAlign.center, 'right' || 'end' => TextAlign.right, 'both' || 'distribute' => TextAlign.justify, _ => TextAlign.left };

// ------------------------------------------------------------------ Word

/// A Word document laid out on pages of its own size and margins.
class WordView extends StatelessWidget {
  const WordView({super.key, required this.doc});
  final WordDoc doc;

  double get _contentW => doc.pageW - doc.margin[1] - doc.margin[3];
  double get _contentH => doc.pageH - doc.margin[0] - doc.margin[2];

  double _paraHeight(Para p, double width) {
    var h = (p.before + p.after) * _pt;
    final w = math.max(40.0, width - (p.indent * _pt) - (p.bullet != null ? 18 : 0));
    if (p.runs.isNotEmpty || p.pics.isEmpty) {
      final tp = TextPainter(
        text: p.runs.isEmpty ? TextSpan(text: ' ', style: TextStyle(fontSize: doc.defaultSize * _pt)) : _span(p.runs, doc.defaultSize, doc.defaultFont),
        textAlign: _align(p.align),
        textDirection: TextDirection.ltr,
        strutStyle: StrutStyle(height: p.lineHeight, forceStrutHeight: false),
      )..layout(maxWidth: w);
      h += tp.height;
      tp.dispose();
    }
    for (final pic in p.pics) {
      final s = math.min(1.0, w / pic.width);
      h += pic.height * s + 4;
    }
    return h;
  }

  double _tableHeight(Table t) {
    final cols = t.rows.fold<int>(0, (m, r) => math.max(m, r.length));
    final widths = _colWidths(t, cols);
    var h = 0.0;
    for (final r in t.rows) {
      var rh = 0.0;
      for (var c = 0; c < r.length; c++) {
        final w = (c < widths.length ? widths[c] : _contentW / cols) - 10;
        rh = math.max(rh, r[c].fold<double>(8, (s, p) => s + _paraHeight(p, w)));
      }
      h += rh;
    }
    return h + 8;
  }

  List<double> _colWidths(Table t, int cols) {
    final sum = t.widths.fold<double>(0, (a, b) => a + b);
    if (t.widths.length == cols && sum > 0) return [for (final w in t.widths) w * math.min(1.0, _contentW / sum)];
    return List.filled(cols, _contentW / math.max(1, cols));
  }

  /// Blocks split into pages by measuring them, plus explicit page breaks.
  List<List<Object>> _paginate() {
    final pages = <List<Object>>[[]];
    var used = 0.0;
    for (final b in doc.blocks) {
      final h = b is Para ? _paraHeight(b, _contentW) : _tableHeight(b as Table);
      final forced = b is Para && b.pageBreakBefore && pages.last.isNotEmpty;
      if (forced || (used + h > _contentH && pages.last.isNotEmpty)) {
        pages.add([]);
        used = 0;
      }
      pages.last.add(b);
      used += h;
    }
    return pages;
  }

  Widget _para(Para p, double width) {
    final text = p.runs.isEmpty
        ? SizedBox(height: doc.defaultSize * _pt * p.lineHeight)
        : Text.rich(
            _span(p.runs, doc.defaultSize, doc.defaultFont),
            textAlign: _align(p.align),
            strutStyle: StrutStyle(height: p.lineHeight, forceStrutHeight: false),
          );
    return Padding(
      padding: EdgeInsets.only(top: p.before * _pt, bottom: p.after * _pt, left: p.indent * _pt),
      child: Column(
        crossAxisAlignment: switch (p.align) { 'center' => CrossAxisAlignment.center, 'right' => CrossAxisAlignment.end, _ => CrossAxisAlignment.stretch },
        children: [
          if (p.runs.isNotEmpty || p.pics.isEmpty)
            p.bullet == null
                ? text
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 18, child: Text(p.bullet!, style: TextStyle(fontSize: doc.defaultSize * _pt, color: Colors.black))),
                    Expanded(child: text),
                  ]),
          for (final pic in p.pics)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Image.memory(pic.bytes, width: math.min(pic.width, width), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const SizedBox()),
            ),
        ],
      ),
    );
  }

  Widget _table(Table t) {
    final cols = t.rows.fold<int>(0, (m, r) => math.max(m, r.length));
    final widths = _colWidths(t, cols);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: m.Table(
        border: m.TableBorder.all(color: const Color(0xFF9E9E9E), width: 0.6),
        defaultVerticalAlignment: m.TableCellVerticalAlignment.top,
        columnWidths: <int, m.TableColumnWidth>{for (var i = 0; i < widths.length; i++) i: m.FixedColumnWidth(widths[i])},
        defaultColumnWidth: const m.FlexColumnWidth(),
        children: [
          for (final r in t.rows)
            m.TableRow(children: [
              for (var c = 0; c < cols; c++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
                  child: c < r.length
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final p in r[c]) _para(p, widths[c] - 10)])
                      : const SizedBox(),
                ),
            ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = _paginate();
    return LayoutBuilder(builder: (context, c) {
      final scale = math.min(1.0, (c.maxWidth - 24) / doc.pageW);
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: pages.length,
        itemBuilder: (_, i) => Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SizedBox(
              width: doc.pageW * scale,
              height: doc.pageH * scale,
              child: FittedBox(
                alignment: Alignment.topLeft,
                child: Container(
                  width: doc.pageW,
                  height: doc.pageH,
                  padding: EdgeInsets.fromLTRB(doc.margin[3], doc.margin[0], doc.margin[1], doc.margin[2]),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: DefaultTextStyle(
                    style: TextStyle(color: Colors.black, fontSize: doc.defaultSize * _pt, fontFamily: doc.defaultFont),
                    child: SelectionArea(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final b in pages[i]) b is Para ? _para(b, _contentW) : _table(b as Table),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

// ------------------------------------------------------------------ PowerPoint

/// Slides drawn at their real proportions: shapes, text boxes, pictures, backgrounds.
class DeckView extends StatelessWidget {
  const DeckView({super.key, required this.deck});
  final Deck deck;

  Widget _shape(Shape s) {
    if (s.pic != null) {
      return Image.memory(s.pic!, fit: BoxFit.fill, errorBuilder: (_, __, ___) => const SizedBox());
    }
    final text = s.paras.every((p) => p.runs.every((r) => r.text.trim().isEmpty))
        ? null
        : FittedBox(
            // Like PowerPoint's "shrink text on overflow".
            fit: BoxFit.scaleDown,
            alignment: switch (s.anchor) { 'ctr' => Alignment.center, 'b' => Alignment.bottomLeft, _ => Alignment.topLeft },
            child: SizedBox(
              width: math.max(10, s.w - 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in s.paras)
                    Padding(
                      padding: EdgeInsets.only(bottom: p.after, left: p.indent),
                      child: p.bullet == null
                          ? Text.rich(_span(p.runs, 18, null), textAlign: _align(p.align))
                          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${p.bullet}  ', style: TextStyle(fontSize: (p.runs.firstOrNull?.size ?? 18) * _pt, color: Color(p.runs.firstOrNull?.color ?? 0xFF000000))),
                              Expanded(child: Text.rich(_span(p.runs, 18, null), textAlign: _align(p.align))),
                            ]),
                    ),
                ],
              ),
            ),
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: s.fill == null ? null : Color(s.fill!),
        border: s.line == null ? null : Border.all(color: Color(s.line!), width: 1.2),
        borderRadius: s.round ? BorderRadius.circular(math.min(s.w, s.h) / 6) : null,
      ),
      alignment: switch (s.anchor) { 'ctr' => Alignment.center, 'b' => Alignment.bottomLeft, _ => Alignment.topLeft },
      child: text,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = math.min(c.maxWidth - 24, 1100.0);
        final scale = w / deck.width;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: deck.slides.length,
          itemBuilder: (_, i) {
            final s = deck.slides[i];
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(children: [
                  SizedBox(
                    width: deck.width * scale,
                    height: deck.height * scale,
                    child: FittedBox(
                      alignment: Alignment.topLeft,
                      child: Container(
                        width: deck.width,
                        height: deck.height,
                        decoration: BoxDecoration(
                          color: Color(s.background ?? 0xFFFFFFFF),
                          image: s.bgPic == null ? null : DecorationImage(image: MemoryImage(s.bgPic!), fit: BoxFit.cover),
                          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: Stack(children: [
                          for (final sh in s.shapes) Positioned(left: sh.x, top: sh.y, width: sh.w, height: sh.h, child: _shape(sh)),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('${i + 1} / ${deck.slides.length}', style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ]),
              ),
            );
          },
        );
      });
}
