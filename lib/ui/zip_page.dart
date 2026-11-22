import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../services/fs.dart';
import '../services/native.dart';
import 'editor_page.dart';
import 'image_page.dart';
import 'widgets.dart';

/// Browse a ZIP like a folder; open single files or extract everything.
class ZipPage extends StatefulWidget {
  const ZipPage({super.key, required this.path, required this.extractTo, required this.onExtract});
  final String path;
  final String extractTo;
  final void Function(Job) onExtract;

  @override
  State<ZipPage> createState() => _ZipPageState();
}

class _ZipPageState extends State<ZipPage> {
  List<ZipItem>? _items;
  String? _error;
  String _prefix = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    readZip(widget.path).then((v) {
      if (mounted) setState(() => _items = v);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  /// Direct children of the current prefix; folders implied by deeper paths count too.
  List<Entry> _children() {
    final dirs = <String, DateTime>{};
    final files = <Entry>[];
    for (final it in _items ?? const <ZipItem>[]) {
      if (!it.name.startsWith(_prefix)) continue;
      final rest = it.name.substring(_prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        final d = rest.substring(0, slash);
        dirs.putIfAbsent(d, () => it.modified);
      } else if (!it.isDir) {
        files.add(Entry(path: it.name, name: rest, isDir: false, size: it.size, modified: it.modified));
      } else {
        dirs.putIfAbsent(rest, () => it.modified);
      }
    }
    final list = [
      for (final d in dirs.entries) Entry(path: '$_prefix${d.key}/', name: d.key, isDir: true, size: 0, modified: d.value),
      ...files,
    ];
    return sortEntries(list, const SortOrder(SortBy.name, true));
  }

  Future<void> _open(Entry e) async {
    if (e.isDir) {
      setState(() => _prefix = e.path);
      return;
    }
    setState(() => _busy = true);
    try {
      final tmp = await getTemporaryDirectory();
      final dest = '${tmp.path}/zip/${DateTime.now().millisecondsSinceEpoch}/${e.name}';
      await extractOne(widget.path, e.path, dest);
      if (!mounted) return;
      final k = e.kind;
      final local = Entry(path: dest, name: e.name, isDir: false, size: e.size, modified: e.modified);
      if (k == Kind.image && e.ext != 'svg') {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImagePage(images: [local], start: 0)));
      } else if (isTextKind(k)) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(path: dest)));
      } else {
        await Native.open(dest, k.mimeFor(e.name));
      }
    } catch (err) {
      if (mounted) toast(context, '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kids = _children();
    final total = (_items ?? []).where((i) => !i.isDir).fold<int>(0, (s, i) => s + i.size);
    return PopScope(
      canPop: _prefix.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final p = _prefix.substring(0, _prefix.length - 1);
        final i = p.lastIndexOf('/');
        setState(() => _prefix = i < 0 ? '' : p.substring(0, i + 1));
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(nameOf(widget.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
            Text(
              _prefix.isEmpty ? (_items == null ? '…' : '${filesText(_items!.where((i) => !i.isDir).length)} · ${fmtSize(total)}') : '/$_prefix',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ]),
          actions: [
            IconButton(
              tooltip: tr('Dezarhivează tot în celălalt panou', 'Extract all to other panel'),
              icon: const Icon(Icons.unarchive_outlined),
              onPressed: _items == null
                  ? null
                  : () {
                      widget.onExtract(Job(JobKind.extract, [widget.path], target: join(widget.extractTo, stemOf(nameOf(widget.path)))));
                      Navigator.of(context).pop();
                    },
            ),
          ],
          bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2)) : null,
        ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)))
            : _items == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: kids.length,
                    itemBuilder: (_, i) {
                      final e = kids[i];
                      return ListTile(
                        leading: EntryIcon(e, size: 36),
                        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(e.isDir ? tr('folder', 'folder') : '${fmtSize(e.size)} · ${fmtListDate(e.modified)}',
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                        onTap: () => _open(e),
                      );
                    },
                  ),
      ),
    );
  }
}
