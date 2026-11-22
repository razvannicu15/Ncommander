import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/store.dart';
import 'widgets.dart';

enum _Type { any, image, video, audio, docs, archive, apk }

enum _Size { any, small, m10, m100, g1 }

enum _Age { any, today, week, month, year }

/// Search by name / mask, type, size, date and text inside files.
/// Returns the tapped entry.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.root});
  final String root;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  final List<Entry> _results = [];
  StreamSubscription<List<Entry>>? _sub;
  bool _running = false;
  bool _searched = false;
  bool _filters = true;

  _Type _type = _Type.any;
  _Size _size = _Size.any;
  _Age _age = _Age.any;
  bool _recursive = true;
  bool _hidden = store.showHidden;
  bool _foldersOnly = false;

  @override
  void dispose() {
    _sub?.cancel();
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  String _typeLabel(_Type t) => switch (t) {
        _Type.any => tr('Orice tip', 'Any type'),
        _Type.image => tr('Imagini', 'Images'),
        _Type.video => tr('Video', 'Video'),
        _Type.audio => tr('Audio', 'Audio'),
        _Type.docs => tr('Documente', 'Documents'),
        _Type.archive => tr('Arhive', 'Archives'),
        _Type.apk => 'APK',
      };

  String _sizeLabel(_Size s) => switch (s) {
        _Size.any => tr('Orice mărime', 'Any size'),
        _Size.small => '< 1 MB',
        _Size.m10 => '> 10 MB',
        _Size.m100 => '> 100 MB',
        _Size.g1 => '> 1 GB',
      };

  String _ageLabel(_Age a) => switch (a) {
        _Age.any => tr('Oricând', 'Any time'),
        _Age.today => tr('Azi', 'Today'),
        _Age.week => tr('7 zile', '7 days'),
        _Age.month => tr('30 de zile', '30 days'),
        _Age.year => tr('Un an', 'A year'),
      };

  SearchQuery _query() {
    final now = DateTime.now();
    return SearchQuery(
      mask: _name.text.trim(),
      kinds: switch (_type) {
        _Type.any => const {},
        _Type.image => const {'image'},
        _Type.video => const {'video'},
        _Type.audio => const {'audio'},
        _Type.docs => const {'pdf', 'doc', 'sheet', 'slides', 'text'},
        _Type.archive => const {'archive'},
        _Type.apk => const {'apk'},
      },
      minSize: switch (_size) { _Size.m10 => 10 << 20, _Size.m100 => 100 << 20, _Size.g1 => 1 << 30, _ => null },
      maxSize: _size == _Size.small ? 1 << 20 : null,
      after: switch (_age) {
        _Age.any => null,
        _Age.today => DateTime(now.year, now.month, now.day),
        _Age.week => now.subtract(const Duration(days: 7)),
        _Age.month => now.subtract(const Duration(days: 30)),
        _Age.year => now.subtract(const Duration(days: 365)),
      },
      content: _text.text,
      recursive: _recursive,
      hidden: _hidden,
      foldersOnly: _foldersOnly,
    );
  }

  void _start() {
    final q = _query();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    _sub?.cancel();
    setState(() {
      _results.clear();
      _running = true;
      _searched = true;
      _filters = false;
    });
    _sub = search(widget.root, q).listen(
      (batch) => setState(() => _results.addAll(batch)),
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
    );
  }

  void _stop() {
    _sub?.cancel();
    setState(() => _running = false);
  }

  String _where(Entry e) {
    final dir = parentOf(e.path);
    if (dir == widget.root) return '.';
    if (isInside(dir, widget.root)) return dir.substring(widget.root.length + (widget.root == '/' ? 0 : 1));
    return dir;
  }

  List<String> get _active => [
        if (_type != _Type.any) _typeLabel(_type),
        if (_size != _Size.any) _sizeLabel(_size),
        if (_age != _Age.any) _ageLabel(_age),
        if (_text.text.trim().isNotEmpty) '„${_text.text.trim()}”',
        if (!_recursive) tr('fără subfoldere', 'no subfolders'),
        if (_foldersOnly) tr('doar foldere', 'folders only'),
      ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = volumes.of(widget.root);
    final rootLabel = v == null ? widget.root : '${volumes.label(v)}${widget.root.substring(v.path.length)}';
    final total = _results.fold<int>(0, (s, e) => s + (e.isDir ? 0 : e.size));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _start(),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: tr('Nume sau mască (*.pdf)', 'Name or mask (*.pdf)'),
            filled: false,
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: tr('Filtre', 'Filters'),
            isSelected: _filters,
            icon: Badge(isLabelVisible: _active.isNotEmpty && !_filters, smallSize: 8, child: const Icon(Icons.tune_rounded)),
            onPressed: () => setState(() => _filters = !_filters),
          ),
          if (_running)
            IconButton(icon: const Icon(Icons.stop_circle_outlined), onPressed: _stop)
          else
            IconButton(icon: const Icon(Icons.search_rounded), onPressed: _start),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(height: 2, child: _running ? const LinearProgressIndicator(minHeight: 2) : null),
        ),
      ),
      body: Column(children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _filters ? _filterPanel(cs, rootLabel) : _summary(cs, rootLabel),
        ),
        if (_searched)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Text(
                _running ? '${tr('Caut…', 'Searching…')}  ${_results.length}' : itemsText(_results.length),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const Spacer(),
              if (total > 0)
                Text(fmtSize(total), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        Expanded(
          child: !_searched
              ? const SizedBox.shrink()
              : _results.isEmpty && !_running
                  ? Center(child: Text(tr('Nimic găsit', 'Nothing found'), style: TextStyle(color: cs.onSurfaceVariant)))
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (_, i) {
                        final e = _results[i];
                        return ListTile(
                          dense: true,
                          leading: EntryIcon(e, size: 34),
                          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
                          subtitle: Text(_where(e), maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            if (!e.isDir) Text(fmtSize(e.size), style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()])),
                            Text(fmtListDate(e.modified),
                                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                          ]),
                          onTap: () => Navigator.pop(context, e),
                        );
                      },
                    ),
        ),
      ]),
    );
  }

  Widget _summary(ColorScheme cs, String rootLabel) => InkWell(
        onTap: () => setState(() => _filters = true),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          color: cs.surfaceContainerLow,
          child: Row(children: [
            Icon(Icons.folder_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                [rootLabel, ..._active].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
            ),
          ]),
        ),
      );

  Widget _filterPanel(ColorScheme cs, String rootLabel) {
    Widget row<T>(IconData icon, List<T> values, T current, String Function(T) label, ValueChanged<T> onPick) => SizedBox(
          height: 46,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(padding: const EdgeInsets.only(right: 8), child: Icon(icon, size: 20, color: cs.onSurfaceVariant)),
            for (final v in values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(label(v)),
                  selected: v == current,
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => onPick(v)),
                ),
              ),
          ]),
        );

    return Container(
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Row(children: [
            Icon(Icons.folder_outlined, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(rootLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant))),
          ]),
        ),
        row(Icons.category_outlined, _Type.values, _type, _typeLabel, (v) => _type = v),
        row(Icons.data_usage_rounded, _Size.values, _size, _sizeLabel, (v) => _size = v),
        row(Icons.schedule_rounded, _Age.values, _age, _ageLabel, (v) => _age = v),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: TextField(
            controller: _text,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _start(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.text_fields_rounded, size: 20),
              hintText: tr('Conține textul (fișiere text)', 'Contains text (text files)'),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(tr('Subfoldere', 'Subfolders')),
                selected: _recursive,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _recursive = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(tr('Ascunse', 'Hidden')),
                selected: _hidden,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _hidden = v),
              ),
            ),
            FilterChip(
              label: Text(tr('Doar foldere', 'Folders only')),
              selected: _foldersOnly,
              visualDensity: VisualDensity.compact,
              onSelected: (v) => setState(() => _foldersOnly = v),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _query().isEmpty ? null : _start,
              icon: const Icon(Icons.search_rounded),
              label: Text(tr('Caută', 'Search')),
            ),
          ),
        ),
      ]),
    );
  }
}
