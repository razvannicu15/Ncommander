import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/store.dart';
import 'widgets.dart';

/// Recursive search by name / mask (TC Alt+F7). Returns the tapped entry.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.root});
  final String root;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctl = TextEditingController();
  final List<Entry> _results = [];
  StreamSubscription<List<Entry>>? _sub;
  bool _running = false;
  bool _searched = false;
  bool _foldersOnly = false;
  bool _hidden = store.showHidden;

  @override
  void dispose() {
    _sub?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _start() {
    final q = _ctl.text.trim();
    if (q.isEmpty) return;
    _sub?.cancel();
    setState(() {
      _results.clear();
      _running = true;
      _searched = true;
    });
    _sub = search(widget.root, q, includeHidden: _hidden).listen(
      (batch) => setState(() => _results.addAll(_foldersOnly ? batch.where((e) => e.isDir) : batch)),
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = volumes.of(widget.root);
    final rootLabel = v == null ? widget.root : '${volumes.label(v)}${widget.root.substring(v.path.length)}';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _start(),
          decoration: InputDecoration(
            hintText: tr('Nume sau mască (*.pdf)', 'Name or mask (*.pdf)'),
            filled: false,
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_running)
            IconButton(icon: const Icon(Icons.stop_circle_outlined), onPressed: _stop)
          else
            IconButton(icon: const Icon(Icons.search_rounded), onPressed: _start),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Column(children: [
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Chip(
                    avatar: const Icon(Icons.folder_outlined, size: 18),
                    label: Text(rootLabel, overflow: TextOverflow.ellipsis),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(tr('Doar foldere', 'Folders only')),
                    selected: _foldersOnly,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) {
                      setState(() => _foldersOnly = v);
                      if (_searched) _start();
                    },
                  ),
                ),
                FilterChip(
                  label: Text(tr('Ascunse', 'Hidden')),
                  selected: _hidden,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    setState(() => _hidden = v);
                    if (_searched) _start();
                  },
                ),
              ]),
            ),
            SizedBox(height: 2, child: _running ? const LinearProgressIndicator(minHeight: 2) : null),
          ]),
        ),
      ),
      body: !_searched
          ? const SizedBox.shrink()
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(children: [
                  Text(
                    _running ? '${tr('Caut…', 'Searching…')}  ${_results.length}' : itemsText(_results.length),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ]),
              ),
              Expanded(
                child: _results.isEmpty && !_running
                    ? Center(child: Text(tr('Nimic găsit', 'Nothing found'), style: TextStyle(color: cs.onSurfaceVariant)))
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final e = _results[i];
                          return ListTile(
                            dense: true,
                            leading: EntryIcon(e, size: 34),
                            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
                            subtitle: Text(
                              '${_where(e)}${e.isDir ? '' : ' · ${fmtSize(e.size)}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                            ),
                            onTap: () => Navigator.pop(context, e),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
