import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/store.dart';
import 'dialogs.dart';
import 'drawer.dart';
import 'editor_page.dart';
import 'image_page.dart';
import 'jobs.dart';
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
      if (!Directory(t.path).existsSync()) t.path = volumes.primary;
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
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ZipPage(path: e.path, extractTo: other.path, onExtract: runner.add)));
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
    runner.add(Job(move ? JobKind.move : JobKind.copy, items.map((e) => e.path).toList(), target: t));
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
    if (store.confirmDelete && !await confirmDelete(context, items)) return;
    runner.add(Job(JobKind.delete, items.map((e) => e.path).toList()));
    cur.clearSelection();
  }

  Future<void> zip() async {
    final items = _sel;
    if (items.isEmpty) return;
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

  void share() {
    final files = _sel.where((e) => !e.isDir).toList();
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
        await _search(p);
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

    Widget tile(String id, IconData icon, String label) => InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(context, id),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: cs.onSecondaryContainer),
            ),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12, height: 1.15)),
          ]),
        );

    final tiles = <Widget>[
      if (has) tile('zip', Icons.folder_zip_outlined, tr('Arhivează', 'Zip')),
      if (has) tile('share', Icons.share_outlined, tr('Distribuie', 'Share')),
      if (single != null && !single.isDir) tile('with', Icons.open_in_new_rounded, tr('Deschide cu', 'Open with')),
      if (has) tile('props', Icons.info_outline_rounded, tr('Proprietăți', 'Properties')),
      if (single != null) tile('path', Icons.content_copy_rounded, tr('Copiază calea', 'Copy path')),
      if (single != null && single.isDir) tile('tab', Icons.tab_rounded, tr('În tab nou', 'In new tab')),
      if (single != null && single.isDir)
        tile('mark', store.isBookmarked(single.path) ? Icons.star_rounded : Icons.star_outline_rounded, tr('Favorite', 'Bookmark')),
      if (single != null && single.isDir) tile('otherOpen', Icons.call_split_rounded, tr('Deschide în celălalt', 'Open in other')),
      tile('all', Icons.select_all_rounded, tr('Selectează tot', 'Select all')),
      tile('mask', Icons.rule_rounded, tr('După mască', 'By mask')),
      if (has) tile('invert', Icons.flip_rounded, tr('Inversează', 'Invert')),
      if (has) tile('none', Icons.deselect_rounded, tr('Deselectează', 'Deselect')),
      if (!has) tile('search', Icons.search_rounded, tr('Caută', 'Search')),
      if (!has) tile('swap', Icons.swap_horiz_rounded, tr('Schimbă panourile', 'Swap panels')),
      if (!has) tile('same', Icons.drag_handle_rounded, tr('Același folder', 'Same folder')),
      tile('settings', Icons.settings_outlined, tr('Setări', 'Settings')),
    ];

    final r = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (has) SheetTitle(single?.name ?? itemsText(items.length)),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              childAspectRatio: 0.95,
              children: tiles,
            ),
          ]),
        ),
      ),
    );
    if (!mounted || r == null) return;
    switch (r) {
      case 'zip':
        await zip();
      case 'share':
        share();
      case 'with':
        await Native.open(single!.path, single.kind.mimeFor(single.name), chooser: true);
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
      case 'settings':
        await openSettings();
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
    final v = volumes.of(cur.path);
    if (!cur.atRoot && (v == null || v.path != cur.path)) {
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
        drawer: LocationsDrawer(
          panel: cur,
          onGo: (p) {
            Navigator.of(context).pop();
            cur.go(p);
          },
          onSettings: () {
            Navigator.of(context).pop();
            openSettings();
          },
        ),
        body: SafeArea(
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

  bool _sideBySide(Size s) => switch (store.layout) {
        PanelLayout.sideBySide => true,
        PanelLayout.stacked => false,
        PanelLayout.auto => s.width >= 600 || s.width > s.height,
      };

  Widget _panels(ColorScheme cs) => LayoutBuilder(builder: (context, c) {
        final row = _sideBySide(MediaQuery.sizeOf(context));
        final total = row ? c.maxWidth : c.maxHeight;
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
              onDrawer: () => _scaffold.currentState?.openDrawer(),
              onAction: (a) => panelAction(panels[i], a),
            );
        final divider = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => setState(() => split = 0.5),
          onHorizontalDragUpdate: row ? (d) => setState(() => split = (split + d.delta.dx / total).clamp(0.2, 0.8)) : null,
          onVerticalDragUpdate: row ? null : (d) => setState(() => split = (split + d.delta.dy / total).clamp(0.2, 0.8)),
          child: Container(
            width: row ? div : double.infinity,
            height: row ? double.infinity : div,
            color: cs.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Container(
              width: row ? 3 : 28,
              height: row ? 28 : 3,
              decoration: BoxDecoration(color: cs.outline.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)),
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
    final dir = row ? (active == 0 ? '→' : '←') : (active == 0 ? '↓' : '↑');
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6), width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(children: [
            _BarButton(icon: Icons.file_copy_outlined, label: '${tr('Copiere', 'Copy')} $dir', enabled: has, onTap: () => copyMove(false)),
            _BarButton(icon: Icons.drive_file_move_outline, label: '${tr('Mutare', 'Move')} $dir', enabled: has, onTap: () => copyMove(true)),
            _BarButton(icon: Icons.drive_file_rename_outline, label: tr('Redenumire', 'Rename'), enabled: n == 1, onTap: rename),
            _BarButton(icon: Icons.create_new_folder_outlined, label: tr('Nou', 'New'), enabled: true, onTap: createNew),
            _BarButton(icon: Icons.delete_outline, label: tr('Ștergere', 'Delete'), enabled: has, onTap: delete, danger: true),
            _BarButton(icon: Icons.more_horiz_rounded, label: tr('Mai mult', 'More'), enabled: true, onTap: more, badge: has ? n : null),
          ]),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.label, required this.enabled, required this.onTap, this.danger = false, this.badge});
  final IconData icon;
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
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Badge(
            isLabelVisible: badge != null,
            label: Text('${badge ?? ''}'),
            child: Icon(icon, color: c, size: 23),
          ),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}
