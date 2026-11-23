import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/remote_ops.dart';
import '../services/vfs.dart';
import '../services/native.dart';
import '../services/store.dart';
import 'connections.dart';
import 'dialogs.dart';
import 'drawer.dart';
import 'editor_page.dart';
import 'image_page.dart';
import 'jobs.dart';
import 'locations_page.dart';
import 'modern.dart';
import 'panel_view.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'widgets.dart';
import 'zip_page.dart';

class CommanderPage extends StatefulWidget {
  const CommanderPage({super.key, this.autoLoad = true});

  /// Tests pre-load the panels themselves.
  final bool autoLoad;

  @override
  State<CommanderPage> createState() => CommanderPageState();
}

class CommanderPageState extends State<CommanderPage> with WidgetsBindingObserver {
  late final List<Panel> panels;
  late final JobRunner runner;
  final _scaffold = GlobalKey<ScaffoldState>();
  int active = store.activePanel;
  double split = 0.5;
  DateTime _lastBack = DateTime(0);

  Panel get cur => panels[active];
  Panel get other => panels[1 - active];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final home = volumes.primary;
    panels = [Panel(0, _valid(store.left), home), Panel(1, _valid(store.right), home)];
    for (final p in panels) {
      p.addListener(_onPanel);
    }
    runner = JobRunner(() => context, _jobDone)..addListener(() => setState(() {}));
    if (widget.autoLoad) {
      for (final p in panels) {
        p.load();
      }
    }
  }

  PanelSaved? _valid(PanelSaved? s) {
    if (s == null) return null;
    for (final t in s.tabs) {
      final ok = isRemote(t.path) ? connOf(t.path) != null : Directory(t.path).existsSync();
      if (!ok) t.path = volumes.primary;
    }
    return s;
  }

  void _onPanel() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final p in panels) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      volumes.refresh();
      for (final p in panels) {
        p.load(keepSelection: true, quiet: true);
      }
    }
  }

  void activatePanel(int i) {
    if (active == i) return;
    setState(() => active = i);
    store.activePanel = i;
    store.save(notify: false);
  }

  void _jobDone(Job j) {
    for (final p in panels) {
      p.load(keepSelection: j.kind != JobKind.delete && j.kind != JobKind.move, quiet: true);
    }
    if (!mounted) return;
    if (j.errors.isNotEmpty) {
      showErrors(context, tr('Unele elemente nu au reușit', 'Some items failed'), j.errors);
    } else if (j.cancelled) {
      toast(context, tr('Oprit', 'Stopped'), icon: Icons.block);
    } else {
      final n = j.kind == JobKind.delete || j.totalFiles == 0 ? j.sources.length : j.totalFiles;
      toast(context, '${jobVerb(j.kind, past: true)} · ${j.kind == JobKind.delete ? itemsText(n) : filesText(n)}', icon: Icons.check_circle_outline);
    }
  }

  // --------------------------------------------------------------- open

  Future<void> open(Entry e) async {
    if (e.isDir) {
      await cur.go(e.path);
      return;
    }
    if (isRemote(e.path)) {
      await _openRemote(e);
      return;
    }
    final k = e.kind;
    if (k == Kind.archive && e.ext == 'zip') {
      await _zipSheet(e);
    } else if (k == Kind.image && e.ext != 'svg') {
      final imgs = cur.entries.where((x) => !x.isDir && x.kind == Kind.image && x.ext != 'svg').toList();
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImagePage(images: imgs, start: imgs.indexOf(e))));
    } else if (isTextKind(k)) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(path: e.path)));
    } else {
      final ok = await Native.open(e.path, k.mimeFor(e.name));
      if (!ok && mounted) await _noApp(e);
    }
  }

  /// Downloads to the cache with a progress dialog; returns the local copy.
  Future<String?> _fetch(Entry e) async {
    var cancelled = false;
    var done = 0;
    late StateSetter setD;
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        setD = set;
        return AlertDialog(
          title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: e.size > 0 ? (done / e.size).clamp(0.0, 1.0) : null),
            const SizedBox(height: 8),
            Text(e.size > 0 ? '${fmtSize(done)} / ${fmtSize(e.size)}' : fmtSize(done),
                style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: Text(tr('Anulează', 'Cancel')),
            ),
          ],
        );
      }),
    );
    try {
      var last = DateTime(0);
      final path = await fetchToCache(e, onBytes: (d) {
        done += d;
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds > 100) {
          last = now;
          try {
            setD(() {});
          } catch (_) {}
        }
      }, cancelled: () => cancelled);
      if (!cancelled) nav.pop();
      return cancelled ? null : path;
    } catch (err) {
      if (!cancelled) nav.pop();
      if (!cancelled && mounted) toast(context, remoteError(err), icon: Icons.error_outline);
      return null;
    }
  }

  Future<void> _openRemote(Entry e, {bool chooser = false}) async {
    final path = await _fetch(e);
    if (path == null || !mounted) return;
    final name = nameOf(path);
    final k = kindOf(name);
    final local = Entry(path: path, name: name, isDir: false, size: e.size, modified: e.modified);
    if (chooser) {
      await Native.open(path, k.mimeFor(name), chooser: true);
    } else if (k == Kind.archive && extOf(name) == 'zip') {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ZipPage(path: path, extractTo: other.remote ? volumes.primary : other.path, onExtract: runner.add)));
    } else if (k == Kind.image && extOf(name) != 'svg') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImagePage(images: [local], start: 0)));
    } else if (isTextKind(k)) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(path: path)));
    } else {
      final ok = await Native.open(path, k.mimeFor(name));
      if (!ok && mounted) await _noApp(local);
    }
  }

  Future<void> _noApp(Entry e) async {
    final r = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SheetTitle(e.name, subtitle: tr('Nicio aplicație nu deschide acest tip', 'No app opens this type')),
          ListTile(leading: const Icon(Icons.article_outlined), title: Text(tr('Deschide ca text', 'Open as text')), onTap: () => Navigator.pop(ctx, 'text')),
          ListTile(leading: const Icon(Icons.apps_rounded), title: Text(tr('Alege aplicația', 'Choose app')), onTap: () => Navigator.pop(ctx, 'any')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted) return;
    if (r == 'text') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(path: e.path)));
    } else if (r == 'any') {
      await Native.open(e.path, '*/*', chooser: true);
    }
  }

  Future<void> _zipSheet(Entry e) async {
    final here = parentOf(e.path);
    final named = join(here, stemOf(e.name));
    final r = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SheetTitle(e.name, subtitle: fmtSize(e.size)),
          ListTile(leading: const Icon(Icons.folder_open_outlined), title: Text(tr('Răsfoiește', 'Browse')), onTap: () => Navigator.pop(ctx, 'browse')),
          ListTile(
            leading: const Icon(Icons.unarchive_outlined),
            title: Text(tr('Dezarhivează în „${stemOf(e.name)}”', 'Extract to "${stemOf(e.name)}"')),
            onTap: () => Navigator.pop(ctx, 'named'),
          ),
          ListTile(leading: const Icon(Icons.move_down_rounded), title: Text(tr('Dezarhivează aici', 'Extract here')), onTap: () => Navigator.pop(ctx, 'here')),
          if (!other.remote)
          ListTile(
            leading: const Icon(Icons.call_split_rounded),
            title: Text(tr('Dezarhivează în celălalt panou', 'Extract to other panel')),
            subtitle: Text(shortPath(other.path), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(ctx, 'other'),
          ),
          ListTile(leading: const Icon(Icons.open_in_new_rounded), title: Text(tr('Deschide cu…', 'Open with…')), onTap: () => Navigator.pop(ctx, 'with')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || r == null) return;
    switch (r) {
      case 'browse':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ZipPage(path: e.path, extractTo: other.remote ? here : other.path, onExtract: runner.add)));
      case 'named':
        runner.add(Job(JobKind.extract, [e.path], target: named));
      case 'here':
        runner.add(Job(JobKind.extract, [e.path], target: here));
      case 'other':
        runner.add(Job(JobKind.extract, [e.path], target: other.path));
      case 'with':
        await Native.open(e.path, Kind.archive.mimeFor(e.name), chooser: true);
    }
  }

  // ------------------------------------------------------------ actions

  List<Entry> get _sel => cur.selectedEntries;

  Future<void> copyMove(bool move) async {
    final items = _sel;
    if (items.isEmpty) return;
    final t = await askTarget(context, move: move, items: items, target: other.path);
    if (t == null || t.isEmpty) return;
    runner.add(Job(move ? JobKind.move : JobKind.copy, items.map((e) => e.path).toList(), target: t, items: items));
    cur.clearSelection();
  }

  Future<void> rename() async {
    final items = _sel;
    if (items.length != 1) return;
    final e = items.first;
    final dir = parentOf(e.path);
    final n = await askName(context,
        title: tr('Redenumește', 'Rename'),
        initial: e.name,
        icon: Icons.drive_file_rename_outline,
        action: tr('Redenumește', 'Rename'),
        exists: (v) => FileSystemEntity.typeSync(join(dir, v), followLinks: false) != FileSystemEntityType.notFound &&
            v.toLowerCase() != e.name.toLowerCase());
    if (n == null || n == e.name) return;
    final v = vfsFor(e.path);
    if (v != null) {
      try {
        await v.rename(e, n);
        await cur.load();
        cur.focus(n);
      } catch (err) {
        if (mounted) toast(context, remoteError(err), icon: Icons.error_outline);
      }
      return;
    }
    try {
      final to = join(dir, n);
      if (e.isDir) {
        await Directory(e.path).rename(to);
      } else {
        await File(e.path).rename(to);
      }
      Native.scan([e.path, to]);
      await cur.load();
      cur.focus(n);
    } catch (err) {
      if (mounted) toast(context, '${tr('Nu am putut redenumi', 'Couldn\'t rename')}: ${err is FileSystemException ? err.osError?.message ?? err.message : err}');
    }
  }

  Future<void> createNew() async {
    final r = await askNew(context, cur.path);
    if (r == null) return;
    final (name, folder) = r;
    final path = join(cur.path, name);
    final v = vfsFor(cur.path);
    if (v != null) {
      try {
        if (folder) {
          await v.mkdir(cur.path, name);
        } else {
          final tmp = File('${Directory.systemTemp.path}/nc_empty_${DateTime.now().microsecondsSinceEpoch}');
          await tmp.writeAsBytes(const []);
          await v.upload(tmp.path, cur.path, name, (_) {}, () => false);
          await tmp.delete();
        }
        await cur.load();
        cur.focus(name);
      } catch (err) {
        if (mounted) toast(context, remoteError(err), icon: Icons.error_outline);
      }
      return;
    }
    try {
      if (folder) {
        await Directory(path).create();
      } else {
        await File(path).create();
      }
      await cur.load();
      cur.focus(name);
      if (!folder && isTextKind(kindOf(name)) && mounted) {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(path: path)));
      }
    } catch (err) {
      if (mounted) toast(context, '${tr('Nu am putut crea', 'Couldn\'t create')}: $err');
    }
  }

  Future<void> delete() async {
    final items = _sel;
    if (items.isEmpty) return;
    final bin = cur.conn != null && cur.conn!.type != ConnType.ftp;
    if (store.confirmDelete && !await confirmDelete(context, items, bin: bin)) return;
    runner.add(Job(JobKind.delete, items.map((e) => e.path).toList(), items: items));
    cur.clearSelection();
  }

  Future<void> zip() async {
    final items = _sel;
    if (items.isEmpty || cur.remote) return;
    final base = items.length == 1 ? stemOf(items.first.name) : nameOf(cur.path);
    final n = await askName(context,
        title: tr('Arhivează ZIP', 'Create ZIP'),
        initial: '${base.isEmpty ? 'arhiva' : base}.zip',
        icon: Icons.folder_zip_outlined,
        action: tr('Arhivează', 'Zip'));
    if (n == null) return;
    runner.add(Job(JobKind.zip, items.map((e) => e.path).toList(), target: cur.path, zipName: n.toLowerCase().endsWith('.zip') ? n : '$n.zip'));
    cur.clearSelection();
  }

  Future<void> share() async {
    var files = _sel.where((e) => !e.isDir).toList();
    if (cur.remote && files.isNotEmpty) {
      final local = <Entry>[];
      for (final e in files) {
        final p = await _fetch(e);
        if (p == null) return;
        local.add(Entry(path: p, name: nameOf(p), isDir: false, size: e.size, modified: e.modified));
      }
      files = local;
    }
    if (files.isEmpty) {
      toast(context, tr('Selectează fișiere, nu foldere', 'Select files, not folders'));
      return;
    }
    final mimes = files.map((e) => e.kind.mimeFor(e.name)).toSet();
    String mime = '*/*';
    if (mimes.length == 1) {
      mime = mimes.first;
    } else {
      final tops = mimes.map((m) => m.split('/').first).toSet();
      if (tops.length == 1) mime = '${tops.first}/*';
    }
    Native.share(files.map((e) => e.path).toList(), mime);
  }

  Future<void> swap() async {
    final a = panels[0].saved, b = panels[1].saved;
    final at = a.tabs.map((t) => TabState(t.path, sort: t.sort)).toList();
    final bt = b.tabs.map((t) => TabState(t.path, sort: t.sort)).toList();
    await Future.wait([panels[0].replaceTabs(bt, b.active), panels[1].replaceTabs(at, a.active)]);
  }

  Future<void> panelAction(Panel p, PanelAction a) async {
    switch (a) {
      case PanelAction.newTab:
        await p.newTab();
      case PanelAction.closeTab:
        await p.closeTab(p.activeTab);
      case PanelAction.filter:
        p.toggleFiltering();
      case PanelAction.sort:
        final s = await askSort(context, p.sort);
        if (s != null) p.setSort(s);
      case PanelAction.hidden:
        store.showHidden = !store.showHidden;
        store.save();
        for (final x in panels) {
          x.refreshView();
        }
      case PanelAction.selectMask:
        final r = await askMask(context);
        if (r != null) p.selectMask(r.$1, add: r.$2);
      case PanelAction.selectAll:
        p.selectAll();
      case PanelAction.invert:
        p.invert();
      case PanelAction.search:
        if (!p.remote) await _search(p);
      case PanelAction.bookmark:
        store.toggleBookmark(p.path, p.title);
        if (mounted) {
          toast(context, store.isBookmarked(p.path) ? tr('Adăugat la favorite', 'Bookmarked') : tr('Scos din favorite', 'Bookmark removed'),
              icon: Icons.star_rounded);
        }
        setState(() {});
      case PanelAction.copyPath:
        await Clipboard.setData(ClipboardData(text: p.path));
        if (mounted) toast(context, tr('Cale copiată', 'Path copied'), icon: Icons.content_copy_rounded);
      case PanelAction.refresh:
        await p.load(keepSelection: true);
      case PanelAction.sameAsOther:
        await panels[1 - panels.indexOf(p)].go(p.path);
    }
  }

  Future<void> _search(Panel p) async {
    final r = await Navigator.of(context).push<Entry>(MaterialPageRoute(builder: (_) => SearchPage(root: p.path)));
    if (r == null) return;
    await p.go(parentOf(r.path), focus: r.name);
  }

  Future<void> more() async {
    final items = _sel;
    final has = items.isNotEmpty;
    final single = items.length == 1 ? items.first : null;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final bytes = items.fold<int>(0, (s, e) => s + (e.isDir ? 0 : e.size));

    Widget tile(String id, IconData icon, String label) => InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(context, id),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(18)),
                child: Icon(icon, color: cs.onSecondaryContainer),
              ),
              const SizedBox(height: 6),
              Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12, height: 1.15)),
            ]),
          ),
        );

    Widget grid(List<Widget> tiles) => GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 4,
          childAspectRatio: 0.92,
          children: tiles,
        );

    Widget chip(String id, IconData icon, String label) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            onPressed: () => Navigator.pop(context, id),
          ),
        );

    Widget label(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(s, style: t.labelMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          ),
        );

    // Header: what the actions apply to.
    final header = has
        ? Container(
            margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
            child: Row(children: [
              single != null
                  ? EntryIcon(single, size: 42)
                  : Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(12)),
                      child: Text('${items.length}', style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w800, fontSize: 16)),
                    ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(single?.name ?? itemsText(items.length),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (bytes > 0) fmtSize(bytes),
                      if (single != null) fmtListDate(single.modified),
                      if (single == null && items.any((e) => e.isDir)) foldersText(items.where((e) => e.isDir).length),
                    ].join(' · '),
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ]),
              ),
            ]),
          )
        : null;

    final actions = <Widget>[
      if (has) tile('share', Icons.share_outlined, tr('Distribuie', 'Share')),
      if (single != null && !single.isDir) tile('with', Icons.open_in_new_rounded, tr('Deschide cu', 'Open with')),
      if (has && !cur.remote) tile('zip', Icons.folder_zip_outlined, tr('Arhivează', 'Zip')),
      if (has) tile('props', Icons.info_outline_rounded, tr('Proprietăți', 'Properties')),
      if (single != null && single.isDir) tile('otherOpen', Icons.call_split_rounded, tr('În celălalt panou', 'In other panel')),
      if (single != null && single.isDir) tile('tab', Icons.tab_rounded, tr('În tab nou', 'In new tab')),
      if (single != null && single.isDir)
        tile('mark', store.isBookmarked(single.path) ? Icons.star_rounded : Icons.star_outline_rounded, tr('Favorite', 'Bookmark')),
      if (single != null) tile('path', Icons.content_copy_rounded, tr('Copiază calea', 'Copy path')),
    ];
    final panelTiles = <Widget>[
      if (!cur.remote) tile('search', Icons.manage_search_rounded, tr('Caută', 'Search')),
      tile('swap', Icons.swap_horiz_rounded, tr('Schimbă panourile', 'Swap panels')),
      tile('same', Icons.drag_handle_rounded, tr('Același folder', 'Same folder')),
      tile('newtab', Icons.tab_rounded, tr('Tab nou', 'New tab')),
    ];

    final r = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (header != null) header,
            if (actions.isNotEmpty) grid(actions),
            label(tr('Selectare', 'Select')),
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 4), children: [
                chip('all', Icons.select_all_rounded, tr('Tot', 'All')),
                chip('mask', Icons.rule_rounded, tr('După mască', 'By mask')),
                if (has) chip('invert', Icons.flip_rounded, tr('Inversează', 'Invert')),
                if (has) chip('none', Icons.deselect_rounded, tr('Nimic', 'None')),
              ]),
            ),
            if (!has) ...[label(tr('Panouri', 'Panels')), grid(panelTiles)],
          ]),
        ),
      ),
    );
    if (!mounted || r == null) return;
    switch (r) {
      case 'zip':
        await zip();
      case 'share':
        await share();
      case 'with':
        if (single!.path.contains('://')) {
          await _openRemote(single, chooser: true);
        } else {
          await Native.open(single.path, single.kind.mimeFor(single.name), chooser: true);
        }
      case 'props':
        await showProperties(context, items);
      case 'path':
        await Clipboard.setData(ClipboardData(text: single!.path));
        if (mounted) toast(context, tr('Cale copiată', 'Path copied'), icon: Icons.content_copy_rounded);
      case 'tab':
        cur.clearSelection();
        await cur.newTab(single!.path);
      case 'mark':
        store.toggleBookmark(single!.path, single.name);
        cur.clearSelection();
      case 'otherOpen':
        cur.clearSelection();
        await other.go(single!.path);
      case 'all':
        cur.selectAll();
      case 'mask':
        final m = await askMask(context);
        if (m != null) cur.selectMask(m.$1, add: m.$2);
      case 'invert':
        cur.invert();
      case 'none':
        cur.clearSelection();
      case 'search':
        await _search(cur);
      case 'swap':
        await swap();
      case 'same':
        await other.go(cur.path);
      case 'newtab':
        await cur.newTab();
    }
  }

  Future<void> openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
    for (final p in panels) {
      p.refreshView();
    }
  }

  // ---------------------------------------------------------------- back

  void _back() {
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
      return;
    }
    if (cur.hasSelection) {
      cur.clearSelection();
      return;
    }
    if (cur.filtering) {
      cur.toggleFiltering();
      return;
    }
    if (!cur.atRoot && !cur.atVolumeRoot) {
      cur.up();
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastBack) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    toast(context, tr('Apasă încă o dată pentru ieșire', 'Press back again to exit'));
  }

  Future<void> connMenu(Conn c, String action) async {
    if (action == 'rename') {
      final n = await askName(context, title: tr('Redenumește', 'Rename'), initial: c.name, icon: connIcon(c.type), action: tr('Salvează', 'Save'));
      if (n != null && n.trim().isNotEmpty) {
        c.name = n.trim();
        await store.save();
        setState(() {});
      }
    } else if (action == 'edit') {
      final e = await editFtp(context, c);
      if (e != null) {
        for (final p in panels) {
          if (rootOf(p.path) == c.root) p.load();
        }
      }
    } else if (action == 'remove' && await confirmRemoveConn(context, c)) {
      for (final p in panels) {
        if (rootOf(p.path) == c.root) await p.go(volumes.primary);
      }
    }
  }

  Future<void> openLocations() async {
    final path = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => LocationsPage(current: cur.path, onConnMenu: connMenu, onSettings: openSettings)));
    if (path != null) await cur.go(path);
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        key: _scaffold,
        drawer: store.modern ? null : LocationsDrawer(
          panel: cur,
          onGo: (p) {
            Navigator.of(context).pop();
            cur.go(p);
          },
          onSettings: () {
            Navigator.of(context).pop();
            openSettings();
          },
          onAddConn: () async {
            Navigator.of(context).pop();
            final c = await addConnection(context);
            if (c != null) await cur.go(c.root);
          },
          onConnMenu: (c, action) async {
            Navigator.of(context).pop();
            await connMenu(c, action);
          },
        ),
        body: store.modern ? _modernBody(cs) : SafeArea(
          bottom: false,
          child: Column(children: [
            Expanded(child: _panels(cs)),
            JobBar(runner: runner),
            _bottomBar(cs),
          ]),
        ),
      ),
    );
  }

  Widget _modernBody(ColorScheme cs) {
    final spec = store.spec!;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final n = cur.selected.length;
    final row = _sideBySide(MediaQuery.sizeOf(context));
    final dir = row
        ? (active == 0 ? Icons.east_rounded : Icons.west_rounded)
        : (active == 0 ? Icons.south_rounded : Icons.north_rounded);
    return Stack(children: [
      Positioned.fill(child: StyleBackground(spec: spec, accent: store.accentColor)),
      SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: _panels(cs, inset: 92 + bottom),
        ),
      ),
      Positioned(
        left: 12,
        right: 12,
        bottom: 12 + bottom,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              JobBar(runner: runner),
              const SizedBox(height: 6),
              _FloatingBar(
                count: n,
                bytes: cur.selectedBytes,
                dir: dir,
                canSearch: !cur.remote,
                onLocations: openLocations,
                onSearch: () => cur.remote ? toast(context, tr('Căutarea merge pe locații locale', 'Search works on local storage')) : _search(cur),
                onMore: more,
                onNew: createNew,
                onCopy: () => copyMove(false),
                onMove: () => copyMove(true),
                onRename: rename,
                onDelete: delete,
              ),
            ]),
          ),
        ),
      ),
    ]);
  }

  bool _sideBySide(Size s) => switch (store.layout) {
        PanelLayout.sideBySide => true,
        PanelLayout.stacked => false,
        PanelLayout.auto => s.width >= 600 || s.width > s.height,
      };

  Widget _panels(ColorScheme cs, {double inset = 0}) => LayoutBuilder(builder: (context, c) {
        final row = _sideBySide(MediaQuery.sizeOf(context));
        final total = row ? c.maxWidth : c.maxHeight;
        final modern = store.modern;
        const div = 10.0;
        final a = ((total - div) * split).floorToDouble();
        Widget view(int i) => PanelView(
              key: ValueKey('panel$i'),
              panel: panels[i],
              active: active == i,
              onActivate: () => activatePanel(i),
              onOpen: (e) {
                activatePanel(i);
                open(e);
              },
              onDrawer: () => modern ? openLocations() : _scaffold.currentState?.openDrawer(),
              onAction: (a) => panelAction(panels[i], a),
              bottomInset: inset > 0 && (row || i == 1) ? inset : 8,
            );
        final divider = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => setState(() => split = 0.5),
          onHorizontalDragUpdate: row ? (d) => setState(() => split = (split + d.delta.dx / total).clamp(0.2, 0.8)) : null,
          onVerticalDragUpdate: row ? null : (d) => setState(() => split = (split + d.delta.dy / total).clamp(0.2, 0.8)),
          child: Container(
            width: row ? div : double.infinity,
            height: row ? double.infinity : div,
            // Modern: just air between the cards, with a faint grip.
            color: modern ? Colors.transparent : cs.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Container(
              width: row ? (modern ? 4 : 3) : (modern ? 36 : 28),
              height: row ? (modern ? 36 : 28) : (modern ? 4 : 3),
              decoration: BoxDecoration(
                color: modern ? cs.onSurface.withValues(alpha: 0.16) : cs.outline.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
        final children = [
          SizedBox(width: row ? a : null, height: row ? null : a, child: view(0)),
          divider,
          Expanded(child: view(1)),
        ];
        return row ? Row(children: children) : Column(children: children);
      });

  Widget _bottomBar(ColorScheme cs) {
    final n = cur.selected.length;
    final has = n > 0;
    final row = _sideBySide(MediaQuery.sizeOf(context));
    // Arrow shows where Copy/Move go, like TC's F5 dialog.
    final dir = row
        ? (active == 0 ? Icons.east_rounded : Icons.west_rounded)
        : (active == 0 ? Icons.south_rounded : Icons.north_rounded);
    // Short screens (phone in landscape): icons only.
    final labels = MediaQuery.sizeOf(context).height >= 500;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6), width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: labels ? 62 : 48,
          child: Row(children: [
            _BarButton(icon: Icons.file_copy_outlined, label: tr('Copiere', 'Copy'), arrow: dir, labels: labels, enabled: has, onTap: () => copyMove(false)),
            _BarButton(icon: Icons.drive_file_move_outline, label: tr('Mutare', 'Move'), arrow: dir, labels: labels, enabled: has, onTap: () => copyMove(true)),
            _BarButton(icon: Icons.drive_file_rename_outline, label: tr('Redenumire', 'Rename'), labels: labels, enabled: n == 1, onTap: rename),
            _BarButton(icon: Icons.create_new_folder_outlined, label: tr('Nou', 'New'), labels: labels, enabled: true, onTap: createNew),
            _BarButton(icon: Icons.delete_outline, label: tr('Ștergere', 'Delete'), labels: labels, enabled: has, onTap: delete, danger: true),
            _BarButton(icon: Icons.more_horiz_rounded, label: tr('Mai mult', 'More'), labels: labels, enabled: true, onTap: more, badge: has ? n : null),
          ]),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton(
      {required this.icon, required this.label, required this.enabled, required this.onTap, this.danger = false, this.badge, this.arrow, this.labels = true});
  final IconData icon;
  final IconData? arrow;
  final bool labels;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool danger;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = !enabled ? cs.onSurface.withValues(alpha: 0.32) : (danger ? cs.error : cs.onSurface);
    return Expanded(
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Badge(
              isLabelVisible: badge != null,
              label: Text('${badge ?? ''}'),
              child: Icon(icon, color: c, size: 23),
            ),
            if (labels) ...[
              const SizedBox(height: 4),
              // Big phone fonts: shrink the label instead of cutting it.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label, maxLines: 1, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w500)),
                    if (arrow != null) ...[const SizedBox(width: 2), Icon(arrow, size: 11, color: c)],
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}


/// Modern styles' bottom bar: floats over the panels and turns into the
/// selection toolbar when something is selected.
class _FloatingBar extends StatelessWidget {
  const _FloatingBar({
    required this.count,
    required this.bytes,
    required this.dir,
    required this.canSearch,
    required this.onLocations,
    required this.onSearch,
    required this.onMore,
    required this.onNew,
    required this.onCopy,
    required this.onMove,
    required this.onRename,
    required this.onDelete,
  });

  final int count, bytes;
  final IconData dir;
  final bool canSearch;
  final VoidCallback onLocations, onSearch, onMore, onNew, onCopy, onMove, onRename, onDelete;

  @override
  Widget build(BuildContext context) {
    final spec = store.spec!;
    final cs = Theme.of(context).colorScheme;
    final accent = store.accentColor;
    final shadow = floatShadow(spec);

    Widget round(IconData icon, String tip, VoidCallback onTap, {Color? color, bool filled = false, double size = 46, bool enabled = true}) => Tooltip(
          message: tip,
          child: Material(
            color: filled ? cs.onSurface.withValues(alpha: 0.08) : Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, size: 22, color: (color ?? cs.onSurface).withValues(alpha: enabled ? 1 : 0.3)),
              ),
            ),
          ),
        );

    Widget withArrow(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 26,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Stack(alignment: Alignment.center, children: [
                Icon(icon, size: 22, color: cs.onSurface),
                Positioned(right: 6, bottom: 7, child: Icon(dir, size: 12, color: accent)),
              ]),
            ),
          ),
        );

    final idle = Row(key: const ValueKey('idle'), children: [
      DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: shadow),
        child: Glass(radius: 31, child: round(Icons.grid_view_rounded, tr('Locații', 'Locations'), onLocations, size: 62)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(31), boxShadow: shadow),
          child: Glass(
            radius: 31,
            height: 62,
            child: InkWell(
              borderRadius: BorderRadius.circular(31),
              onTap: onSearch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(children: [
                  Icon(Icons.search_rounded, color: cs.onSurfaceVariant.withValues(alpha: canSearch ? 1 : 0.4)),
                  const SizedBox(width: 10),
                  Text(tr('Caută', 'Search'), style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant.withValues(alpha: canSearch ? 1 : 0.4))),
                  const Spacer(),
                  InkResponse(onTap: onMore, radius: 22, child: Icon(Icons.more_horiz_rounded, color: cs.onSurfaceVariant)),
                ]),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Tooltip(
        message: tr('Nou', 'New'),
        child: Material(
          color: accent,
          elevation: 0,
          shadowColor: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onNew,
            child: Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10))]),
              child: Icon(Icons.add_rounded, size: 28, color: cs.onPrimary),
            ),
          ),
        ),
      ),
    ]);

    final selecting = DecoratedBox(
      key: const ValueKey('sel'),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(32), boxShadow: shadow),
      child: Glass(
        radius: 32,
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Container(
            height: 46,
            padding: const EdgeInsets.fromLTRB(8, 0, 14, 0),
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(23)),
            child: Row(children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cs.onPrimary.withValues(alpha: 0.16), shape: BoxShape.circle),
                child: Text('$count', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: cs.onPrimary)),
              ),
              if (bytes > 0) ...[
                const SizedBox(width: 8),
                Text(fmtSize(bytes), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: cs.onPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ]),
          ),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              withArrow(Icons.file_copy_outlined, tr('Copiere', 'Copy'), onCopy),
              withArrow(Icons.drive_file_move_outline, tr('Mutare', 'Move'), onMove),
              round(Icons.drive_file_rename_outline, tr('Redenumire', 'Rename'), onRename, enabled: count == 1),
              round(Icons.delete_outline_rounded, tr('Ștergere', 'Delete'), onDelete, color: cs.error),
              round(Icons.more_horiz_rounded, tr('Mai mult', 'More'), onMore, filled: true),
            ]),
          ),
        ]),
      ),
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
      ),
      child: count > 0 ? selecting : idle,
    );
  }
}
