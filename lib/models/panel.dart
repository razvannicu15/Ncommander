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
    if (v.isEmpty) return;
    String sig(List<Volume> l) => l.map((x) => '${x.path}|${x.label}|${x.free ~/ (1 << 26)}').join(',');
    if (sig(v) != sig(value)) value = v;
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

/// "net://ftp" / "net://cloud": the saved connections listed in a panel.
const netFtp = 'net://ftp', netCloud = 'net://cloud';

/// "net://cloud/+gdrive": the add-a-connection rows.
const netNew = '/+';

bool isNetList(String path) => path == netFtp || path == netCloud;

String netTitle(String path) => path == netFtp ? 'FTP' : 'Cloud';

List<Entry> netEntries(String path) {
  final ftp = path == netFtp;
  final zero = DateTime.fromMillisecondsSinceEpoch(0);
  Entry add(ConnType t, String label) => Entry(path: '$path$netNew${t.name}', name: '＋ $label', isDir: false, size: 0, modified: zero, mime: 'nc/add');
  return [
    for (final c in store.conns.where((c) => ftp ? c.type == ConnType.ftp : (c.type == ConnType.gdrive || c.type == ConnType.onedrive)))
      Entry(path: c.root, name: c.name, isDir: true, size: 0, modified: zero, id: c.id, mime: 'nc/${c.type.name}'),
    // Last rows: add a connection of that kind, straight away.
    if (ftp)
      add(ConnType.ftp, tr('Server FTP nou', 'New FTP server'))
    else ...[
      add(ConnType.gdrive, 'Google Drive'),
      add(ConnType.onedrive, 'OneDrive'),
    ],
  ];
}

/// True once a physical keyboard is used (from the start on Windows): shows the row cursor.
final keyboardUsed = ValueNotifier<bool>(Platform.isWindows);

Conn? connOf(String path) {
  if (!isRemote(path)) return null;
  final root = rootOf(path);
  return store.conn(root.substring(root.indexOf('://') + 3));
}

/// One side of the commander: tabs, listing, selection.
class Panel extends ChangeNotifier {
  Panel(this.side, PanelSaved? saved, String home) {
    table = saved?.view == null ? store.table : saved!.view == 'table';
    grid = saved?.view == 'grid';
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

  /// Keyboard cursor (name of the row), like Total Commander's.
  String? cursor;
  int cursorTick = 0;

  /// This panel's view (TC switches views per panel): compact table, or
  /// thumbnails (wins over [table]).
  bool table = false;
  bool grid = false;

  void setView({bool table = false, bool grid = false}) {
    this.grid = grid;
    if (!grid) this.table = table;
    cursorTick++;
    _changed();
  }

  /// Tiles per row in the thumbnail grid (arrow keys move by a row).
  int gridCols = 1;

  /// The ".." row is shown (and can hold the cursor, as in TC).
  bool get hasParentRow => store.showParent && !atRoot && !atVolumeRoot && filter.isEmpty;

  static const parentName = '..';

  /// Cursor on "..": right after entering a folder, or moved there.
  bool get cursorOnParent => hasParentRow && (cursor == parentName || cursor == null || !entries.any((e) => e.name == cursor));

  Entry? get cursorEntry {
    if (cursorOnParent) return null;
    if (cursor == null) return entries.isEmpty ? null : entries.first;
    return entries.where((e) => e.name == cursor).firstOrNull ?? (entries.isEmpty ? null : entries.first);
  }

  void setCursor(String? name, {bool notify = true}) {
    cursor = name;
    cursorTick++;
    if (notify) notifyListeners();
  }

  /// Moves the cursor by [delta] rows (clamped); [select] toggles the row it leaves (Shift+arrows).
  void moveCursor(int delta, {bool select = false}) {
    // Rows as the list shows them: ".." first when it's there.
    final names = [if (hasParentRow) parentName, ...entries.map((e) => e.name)];
    if (names.isEmpty) return;
    var from = cursorOnParent ? 0 : names.indexOf(cursor ?? '');
    if (from < 0) from = 0;
    if (select && names[from] != parentName) {
      final e = entries.firstWhere((x) => x.name == names[from]);
      if (!selected.remove(e.path)) selected.add(e.path);
    }
    setCursor(names[(from + delta).clamp(0, names.length - 1)]);
  }

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;
  int _loadId = 0;

  int get activeTab => _active;
  TabState get tab => tabs[_active.clamp(0, tabs.length - 1)];
  String get path => tab.path;
  SortOrder get sort => tab.sort;

  bool get atRoot => path == '/';

  /// Top of internal storage / SD card: nothing useful above it.
  bool get atVolumeRoot => isNetList(path) || (isRemote(path) ? path == rootOf(path) && !inZip : volumes.of(path)?.path == path);

  /// Browsing inside a ZIP archive.
  bool get inZip => path.startsWith('zip://');

  /// The archive file behind a zip:// path.
  String? get zipFile => inZip ? conn?.host : null;

  bool get remote => isRemote(path);

  /// Connection behind a remote path.
  Conn? get conn => connOf(path);
  bool get hasSelection => selected.isNotEmpty;

  List<Entry> get selectedEntries => entries.where((e) => selected.contains(e.path)).toList();
  int get selectedBytes => selectedEntries.fold(0, (s, e) => s + (e.isDir ? 0 : e.size));
  int get fileCount => entries.where((e) => !e.isDir).length;
  int get dirCount => entries.where((e) => e.isDir).length;

  PanelSaved get saved => PanelSaved(tabs, _active, view: grid ? 'grid' : (table ? 'table' : 'list'));

  Future<void> load({bool keepSelection = false, bool quiet = false}) async {
    final id = ++_loadId;
    final p = path;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    final v = vfsFor(p);
    if (isNetList(p)) {
      // The saved servers, shown as folders (Windows FTP / cloud button).
      _raw = netEntries(p);
      error = null;
    } else if (isRemote(p) && v == null) {
      if (id != _loadId) return;
      _raw = [];
      error = tr('Conexiunea a fost ștearsă', 'The connection was deleted');
    } else if (v != null && v.conn.needsUnlock && !await store.ensureUnlocked()) {
      if (id != _loadId) return;
      _raw = [];
      error = tr('Parolele sunt blocate: introdu parola principală', 'Passwords are locked: enter the master password');
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

  /// Last folder visited on each Windows drive, so a drive button returns there.
  final Map<String, String> lastOnDrive = {};

  Future<void> go(String newPath, {String? focus}) async {
    if (Platform.isWindows && !isRemote(path) && path.length > 2 && path[1] == ':') {
      lastOnDrive[path.substring(0, 2).toUpperCase()] = path;
    }
    tab.path = newPath;
    filter = '';
    filtering = false;
    focusName = focus;
    focusTick++;
    cursor = focus;
    _changed();
    await load();
  }

  Future<void> up() async {
    if (atRoot) return;
    // Leaving an archive: back to its folder, on the archive.
    final z = zipFile;
    if (z != null && path == rootOf(path)) {
      await go(parentOf(z), focus: nameOf(z));
      return;
    }
    await go(parentOf(path), focus: nameOf(path));
  }

  /// Scrolls to and flashes [name] (after create / rename).
  void focus(String name) {
    focusName = name;
    cursor = name;
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
  /// Shift+click: selects from the cursor row to [e].
  void selectSpan(Entry e) {
    final a = entries.indexWhere((x) => x.name == cursor);
    final b = entries.indexOf(e);
    if (a < 0 || b < 0) {
      toggle(e);
      return;
    }
    for (var i = a < b ? a : b; i <= (a < b ? b : a); i++) {
      selected.add(entries[i].path);
    }
    notifyListeners();
  }

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
  List<(String, String)> crumbs() => _crumbsOf(path);

  List<(String, String)> _crumbsOf(String path) {
    if (isNetList(path)) return [(netTitle(path), path)];
    if (isRemote(path)) {
      final root = rootOf(path);
      final c = connOf(path);
      // In an archive the path continues from the folder that holds it.
      final out = <(String, String)>[
        if (c?.type == ConnType.zip) ..._crumbsOf(parentOf(c!.host)),
        (c?.name ?? '?', root),
      ];
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
    if (isNetList(t.path)) return netTitle(t.path);
    if (isRemote(t.path)) return t.path == rootOf(t.path) ? (connOf(t.path)?.name ?? '?') : nameOf(t.path);
    final v = volumes.of(t.path);
    if (v != null && v.path == t.path) return volumes.label(v);
    return t.path == '/' ? '/' : nameOf(t.path);
  }
}
