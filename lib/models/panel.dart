import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/store.dart';
import '../services/vfs.dart';
import '../services/win.dart';
import 'entry.dart';

/// Storage volumes (internal, SD card, USB), refreshed on start and resume.
class Volumes extends ValueNotifier<List<Volume>> {
  Volumes() : super([]);

  Future<void> refresh() async {
    final v = await Native.volumes();
    if (v.isNotEmpty) value = v;
  }

  String get primary => value.firstWhere((v) => v.primary, orElse: () => value.isNotEmpty ? value.first : _fallback).path;

  static final _fallback = Volume(path: '/storage/emulated/0', label: '', removable: false, primary: true);

  Volume? of(String path) {
    Volume? best;
    for (final v in value) {
      if (isInside(path, v.path) && (best == null || v.path.length > best.path.length)) best = v;
    }
    return best;
  }

  /// Where a fresh panel opens: the user folder on Windows, internal storage on Android.
  String get home => Platform.isWindows ? winHome : primary;

  String label(Volume v) {
    if (Platform.isWindows) return '${v.label.isNotEmpty ? v.label : tr('Disc local', 'Local disk')} (${v.path.substring(0, 2)})';
    if (v.primary) return tr('Memorie internă', 'Internal storage');
    if (v.label.isNotEmpty) return v.label;
    return v.removable ? tr('Card SD', 'SD card') : nameOf(v.path);
  }
}

final volumes = Volumes();

Conn? connOf(String path) {
  if (!isRemote(path)) return null;
  final root = rootOf(path);
  return store.conn(root.substring(root.indexOf('://') + 3));
}

/// One side of the commander: tabs, listing, selection.
class Panel extends ChangeNotifier {
  Panel(this.side, PanelSaved? saved, String home) {
    if (saved != null) {
      tabs.addAll(saved.tabs);
      _active = saved.active;
    } else {
      tabs.add(TabState(home));
    }
  }

  final int side;
  final List<TabState> tabs = [];
  int _active = 0;

  List<Entry> _raw = [];
  List<Entry> entries = [];
  final Set<String> selected = {};
  bool loading = false;
  String? error;
  String filter = '';
  bool filtering = false;

  /// Name to scroll to and flash after a load (the folder we came up from).
  String? focusName;
  int focusTick = 0;

  int total = 0, free = 0;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;
  int _loadId = 0;

  int get activeTab => _active;
  TabState get tab => tabs[_active.clamp(0, tabs.length - 1)];
  String get path => tab.path;
  SortOrder get sort => tab.sort;

  bool get atRoot => path == '/';

  /// Top of internal storage / SD card: nothing useful above it.
  bool get atVolumeRoot => isRemote(path) ? path == rootOf(path) : volumes.of(path)?.path == path;

  bool get remote => isRemote(path);

  /// Connection behind a remote path.
  Conn? get conn => connOf(path);
  bool get hasSelection => selected.isNotEmpty;

  List<Entry> get selectedEntries => entries.where((e) => selected.contains(e.path)).toList();
  int get selectedBytes => selectedEntries.fold(0, (s, e) => s + (e.isDir ? 0 : e.size));
  int get fileCount => entries.where((e) => !e.isDir).length;
  int get dirCount => entries.where((e) => e.isDir).length;

  PanelSaved get saved => PanelSaved(tabs, _active);

  Future<void> load({bool keepSelection = false, bool quiet = false}) async {
    final id = ++_loadId;
    final p = path;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    final v = vfsFor(p);
    if (isRemote(p) && v == null) {
      if (id != _loadId) return;
      _raw = [];
      error = tr('Conexiunea a fost ștearsă', 'The connection was deleted');
    } else if (v != null) {
      try {
        final list = await v.list(p);
        if (id != _loadId) return;
        _raw = list;
        error = null;
      } catch (e) {
        if (id != _loadId) return;
        _raw = [];
        error = remoteError(e);
      }
    } else {
      final r = await listDir(p);
      if (id != _loadId) return;
      _raw = r.entries;
      error = r.error;
    }
    loading = false;
    if (!keepSelection) {
      selected.clear();
    } else {
      final paths = _raw.map((e) => e.path).toSet();
      selected.removeWhere((s) => !paths.contains(s));
    }
    _apply();
    _watchDir(p);
    _space(p);
    notifyListeners();
  }

  Future<void> _space(String p) async {
    var (t, f) = (0, 0);
    final v = vfsFor(p);
    if (v != null) {
      try {
        final s = await v.space();
        if (s != null) (t, f) = s;
      } catch (_) {}
    } else if (!isRemote(p)) {
      (t, f) = await Native.space(p);
    }
    if (p != path) return;
    if (t != total || f != free) {
      total = t;
      free = f;
      notifyListeners();
    }
  }

  void _apply() {
    var list = _raw;
    if (!store.showHidden) list = list.where((e) => !e.hidden).toList();
    if (filter.isNotEmpty) list = list.where((e) => matchesMask(e.name, filter)).toList();
    entries = sortEntries(list, sort, foldersFirst: store.foldersFirst);
  }

  /// Re-applies settings (hidden files, folders first) without reloading.
  void refreshView() {
    _apply();
    selected.removeWhere((s) => !entries.any((e) => e.path == s));
    notifyListeners();
  }

  /// Off in tests (real file watchers outlive a test).
  static bool watchEnabled = true;

  void _watchDir(String p) {
    _watch?.cancel();
    _watch = null;
    if (!watchEnabled || isRemote(p)) return;
    try {
      _watch = Directory(p).watch().listen((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 450), () {
          if (path == p) load(keepSelection: true, quiet: true);
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  void _changed() {
    if (side == 0) {
      store.left = saved;
    } else {
      store.right = saved;
    }
    store.save(notify: false);
    notifyListeners();
  }

  Future<void> go(String newPath, {String? focus}) async {
    tab.path = newPath;
    filter = '';
    filtering = false;
    focusName = focus;
    focusTick++;
    _changed();
    await load();
  }

  Future<void> up() async {
    if (atRoot) return;
    await go(parentOf(path), focus: nameOf(path));
  }

  /// Scrolls to and flashes [name] (after create / rename).
  void focus(String name) {
    focusName = name;
    focusTick++;
    notifyListeners();
  }

  void setSort(SortOrder s) {
    tab.sort = s;
    _apply();
    _changed();
  }

  void setFilter(String f) {
    filter = f;
    _apply();
    notifyListeners();
  }

  void toggleFiltering() {
    filtering = !filtering;
    if (!filtering) setFilter('');
    notifyListeners();
  }

  // ---------------------------------------------------------- selection

  void toggle(Entry e) {
    if (!selected.remove(e.path)) selected.add(e.path);
    notifyListeners();
  }

  /// Selects everything between the last selected row and [e] (long-press drag-less range).
  void selectRange(Entry e) {
    final idx = entries.indexOf(e);
    int? anchor;
    for (var i = 0; i < entries.length; i++) {
      if (selected.contains(entries[i].path)) {
        if (anchor == null || (i - idx).abs() < (anchor - idx).abs()) anchor = i;
      }
    }
    if (anchor == null) {
      toggle(e);
      return;
    }
    final a = anchor < idx ? anchor : idx, b = anchor < idx ? idx : anchor;
    for (var i = a; i <= b; i++) {
      selected.add(entries[i].path);
    }
    notifyListeners();
  }

  void selectAll() {
    selected.addAll(entries.map((e) => e.path));
    notifyListeners();
  }

  void invert() {
    final all = entries.map((e) => e.path).toSet();
    final next = all.difference(selected);
    selected
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void selectMask(String mask, {bool add = true}) {
    for (final e in entries) {
      if (matchesMask(e.name, mask)) {
        add ? selected.add(e.path) : selected.remove(e.path);
      }
    }
    notifyListeners();
  }

  void clearSelection() {
    if (selected.isEmpty) return;
    selected.clear();
    notifyListeners();
  }

  void selectNames(Iterable<String> names) {
    selected
      ..clear()
      ..addAll(entries.where((e) => names.contains(e.name)).map((e) => e.path));
    notifyListeners();
  }

  // --------------------------------------------------------------- tabs

  Future<void> newTab([String? at]) async {
    tabs.insert(_active + 1, TabState(at ?? path, sort: sort));
    _active++;
    _changed();
    await load();
  }

  Future<void> switchTab(int i) async {
    if (i == _active || i < 0 || i >= tabs.length) return;
    _active = i;
    _changed();
    await load();
  }

  Future<void> closeTab(int i) async {
    if (tabs.length <= 1) return;
    tabs.removeAt(i);
    if (_active >= tabs.length) _active = tabs.length - 1;
    if (i < _active) _active--;
    _changed();
    await load();
  }

  /// Takes over another panel's tabs (used to swap panels).
  Future<void> replaceTabs(List<TabState> next, int active) async {
    tabs
      ..clear()
      ..addAll(next.map((t) => TabState(t.path, sort: t.sort)));
    _active = active.clamp(0, tabs.length - 1);
    _changed();
    await load();
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  /// "Memorie internă / Download / Telegram" style crumbs: (label, path).
  List<(String, String)> crumbs() {
    if (remote) {
      final root = rootOf(path);
      final out = <(String, String)>[(conn?.name ?? '?', root)];
      var cur = root;
      for (final part in relOf(path).split('/').where((s) => s.isNotEmpty)) {
        cur = join(cur, part);
        out.add((part, cur));
      }
      return out;
    }
    final v = volumes.of(path);
    final out = <(String, String)>[];
    String base;
    if (v != null) {
      out.add((volumes.label(v), v.path));
      base = v.path;
    } else {
      out.add(('/', '/'));
      base = '/';
    }
    final rest = path.length > base.length ? path.substring(base.length) : '';
    var cur = base;
    for (final part in rest.split('/').where((s) => s.isNotEmpty)) {
      cur = join(cur, part);
      out.add((part, cur));
    }
    return out;
  }

  /// Title for a tab chip.
  String get title {
    if (remote) return titleOf(tab);
    final v = volumes.of(path);
    if (v != null && v.path == path) return volumes.label(v);
    return path == '/' ? '/' : nameOf(path);
  }

  String titleOf(TabState t) {
    if (isRemote(t.path)) return t.path == rootOf(t.path) ? (connOf(t.path)?.name ?? '?') : nameOf(t.path);
    final v = volumes.of(t.path);
    if (v != null && v.path == t.path) return volumes.label(v);
    return t.path == '/' ? '/' : nameOf(t.path);
  }
}
