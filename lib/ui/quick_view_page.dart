import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/office.dart';

/// Formats the quick view (F3) can show.
bool canQuickView(String name) {
  final e = extOf(name);
  return e == 'pdf' || officeExts.contains(e);
}

/// F3 viewer for PDF and Office documents (docx, xlsx, pptx).
class QuickViewPage extends StatelessWidget {
  const QuickViewPage({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = nameOf(path);
    final ext = extOf(name);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
        const SingleActivator(LogicalKeyboardKey.f3): () => Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: ext == 'pdf' ? cs.surfaceContainerHigh : cs.surfaceContainerLow,
          appBar: AppBar(
            titleSpacing: 0,
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(tr('Deschide', 'Open')),
                  onPressed: () => Native.open(path, kindOf(name).mimeFor(name)),
                ),
              ),
            ],
          ),
          body: ext == 'pdf' ? PdfViewer.file(path) : _Office(path: path),
        ),
      ),
    );
  }
}

class _Office extends StatefulWidget {
  const _Office({required this.path});
  final String path;
  @override
  State<_Office> createState() => _OfficeState();
}

class _OfficeState extends State<_Office> {
  OfficeContent? _c;
  String? _err;
  int _sheet = 0;

  @override
  void initState() {
    super.initState();
    readOffice(widget.path).then((c) {
      if (mounted) setState(() => _c = c);
    }, onError: (e) {
      if (mounted) setState(() => _err = '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_err != null) {
      return Center(child: Text(tr('Nu am putut citi documentul', 'Couldn\'t read the document'), style: TextStyle(color: cs.onSurfaceVariant)));
    }
    final c = _c;
    if (c == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    if (c.sheets.isNotEmpty) return _sheets(cs, c.sheets);
    if (c.slides.isNotEmpty) return _slides(cs, c.slides);
    if (c.paras.isEmpty) return Center(child: Text(tr('Documentul e gol', 'The document is empty'), style: TextStyle(color: cs.onSurfaceVariant)));
    return _doc(cs, c.paras);
  }

  /// Word: the text on a white page.
  Widget _doc(ColorScheme cs, List<DocPara> paras) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Container(
                padding: const EdgeInsets.fromLTRB(48, 44, 48, 56),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 2))],
                ),
                child: SelectionArea(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final p in paras)
                      Padding(
                        padding: EdgeInsets.only(top: p.heading > 0 ? 14 : 0, bottom: p.heading > 0 ? 6 : 8),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (p.bullet) const Padding(padding: EdgeInsets.only(right: 8, left: 12), child: Text('•', style: TextStyle(color: Color(0xFF333333)))),
                          Expanded(
                            child: Text(
                              p.text,
                              style: TextStyle(
                                color: const Color(0xFF1F1F1F),
                                height: 1.45,
                                fontSize: switch (p.heading) { 1 => 24, 2 => 19, 3 => 16.5, _ => 14.5 },
                                fontWeight: p.heading > 0 ? FontWeight.w700 : FontWeight.w400,
                              ),
                            ),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ],
      );

  /// Excel: one tab per sheet, a grid with column letters and row numbers.
  Widget _sheets(ColorScheme cs, List<Sheet> sheets) {
    final s = sheets[_sheet.clamp(0, sheets.length - 1)];
    final cols = s.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m).clamp(1, 60);
    String letter(int i) => i < 26 ? String.fromCharCode(65 + i) : '${String.fromCharCode(64 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}';
    final line = BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7), width: 0.6);
    Widget cell(String t, {bool head = false, double w = 120, TextAlign align = TextAlign.left}) => Container(
          width: w,
          height: 28,
          alignment: align == TextAlign.right ? Alignment.centerRight : (head ? Alignment.center : Alignment.centerLeft),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: head ? cs.surfaceContainerHigh : cs.surface, border: Border(right: line, bottom: line)),
          child: Text(t,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: head ? FontWeight.w600 : FontWeight.w400, color: head ? cs.onSurfaceVariant : cs.onSurface)),
        );
    final grid = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 44 + cols * 120.0,
        child: ListView.builder(
          itemCount: s.rows.length + 1,
          itemBuilder: (_, r) {
            if (r == 0) {
              return Row(children: [cell('', head: true, w: 44), for (var c = 0; c < cols; c++) cell(letter(c), head: true)]);
            }
            final row = s.rows[r - 1];
            return Row(children: [
              cell('$r', head: true, w: 44),
              for (var c = 0; c < cols; c++)
                cell(c < row.length ? row[c] : '', align: c < row.length && double.tryParse(row[c]) != null ? TextAlign.right : TextAlign.left),
            ]);
          },
        ),
      ),
    );
    return Column(children: [
      Expanded(child: SelectionArea(child: grid)),
      if (sheets.length > 1)
        Container(
          height: 40,
          color: cs.surfaceContainer,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), children: [
            for (var i = 0; i < sheets.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(sheets[i].name),
                  visualDensity: VisualDensity.compact,
                  selected: i == _sheet,
                  onSelected: (_) => setState(() => _sheet = i),
                ),
              ),
          ]),
        ),
    ]);
  }

  /// PowerPoint: one card per slide with its text.
  Widget _slides(ColorScheme cs, List<Slide> slides) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        itemCount: slides.length,
        itemBuilder: (_, i) {
          final s = slides[i];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 26),
                constraints: const BoxConstraints(minHeight: 200),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 2))],
                ),
                child: SelectionArea(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.primary)),
                    const SizedBox(height: 8),
                    if (s.paragraphs.isNotEmpty)
                      Text(s.paragraphs.first, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: Color(0xFF1F1F1F))),
                    for (final p in s.paragraphs.skip(1))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('•  $p', style: const TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF333333))),
                      ),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}
