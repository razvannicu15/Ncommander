import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/i18n.dart';
import '../core/themes.dart';
import '../models/entry.dart';
import 'secrets.dart';

enum PanelLayout { auto, sideBySide, stacked }

/// Theme colours offered in Settings (no pink unless asked for).
const themeColors = <int>[0xFFD9822B, 0xFF2B5CE6, 0xFF0E7C66, 0xFF3F51B5, 0xFF6750A4, 0xFF00838F, 0xFFB3261E, 0xFF5D6B7A];

/// zip: an archive opened in a panel (not saved; [Conn.host] is the zip's path).
enum ConnType { ftp, gdrive, onedrive, zip }

/// A saved network / cloud location. Lives in the app's private storage.
class Conn {
  Conn({
    required this.id,
    required this.type,
    required this.name,
    this.host = '',
    this.port = 21,
    this.user = '',
    this.password = '',
    this.tls = false,
    this.folder = '/',
    this.account = '',
    this.token = '',
    this.clearData = false,
  });

  final String id;
  final ConnType type;
  String name;
  String host;
  int port;
  String user;
  String password;
  bool tls;
  String folder;

  /// Cloud account (e-mail / display name).
  String account;

  /// OneDrive refresh token.
  String token;

  /// FTPS server that only accepts clear data connections (login stays encrypted).
  bool clearData;

  /// What goes to disk instead of [password] / [token] (see secrets.dart).
  String sealedPassword = '', sealedToken = '';
  String? _fromPwd, _fromTok; // the clear text the sealed values were made from

  /// Still encrypted with the master password (not unlocked this session).
  Uint8List? lockedPwd, lockedTok;
  bool get needsUnlock => lockedPwd != null || lockedTok != null;

  String get root => '${type.name}://$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'host': host,
        'port': port,
        'user': user,
        'pwd': sealedPassword,
        'tls': tls,
        'folder': folder,
        'account': account,
        'tok': sealedToken,
        'clearData': clearData,
      };

  static Conn? fromJson(Map j) {
    final t = ConnType.values.where((v) => v.name == j['type']).firstOrNull;
    if (t == null || j['id'] is! String) return null;
    return Conn(
      id: j['id'] as String,
      type: t,
      name: (j['name'] as String?) ?? '',
      host: (j['host'] as String?) ?? '',
      port: (j['port'] as int?) ?? 21,
      user: (j['user'] as String?) ?? '',
      password: (j['password'] as String?) ?? '',
      tls: j['tls'] == true,
      folder: (j['folder'] as String?) ?? '/',
      account: (j['account'] as String?) ?? '',
      token: (j['token'] as String?) ?? '', // clear text from older versions
      clearData: j['clearData'] == true,
    )
      ..sealedPassword = (j['pwd'] as String?) ?? ''
      ..sealedToken = (j['tok'] as String?) ?? '';
  }
}

class Bookmark {
  Bookmark(this.path, this.name);
  final String path;
  String name;
  Map<String, dynamic> toJson() => {'path': path, 'name': name};
}

/// Saved per tab, so panels reopen where they were.
class TabState {
  TabState(this.path, {this.sort = const SortOrder(SortBy.name, true)});
  String path;
  SortOrder sort;
  Map<String, dynamic> toJson() => {'path': path, 'sort': sort.toJson()};
  static TabState fromJson(Map j) => TabState(j['path'] as String, sort: SortOrder.fromJson(j['sort']));
}

class PanelSaved {
  PanelSaved(this.tabs, this.active, {this.view});
  final List<TabState> tabs;
  final int active;

  /// 'list', 'table' or 'grid'; null = the default from Settings.
  final String? view;
  Map<String, dynamic> toJson() => {'tabs': tabs.map((t) => t.toJson()).toList(), 'active': active, if (view != null) 'view': view};
  static PanelSaved? fromJson(Object? j) {
    if (j is! Map) return null;
    final tabs = ((j['tabs'] as List?) ?? []).whereType<Map>().map(TabState.fromJson).toList();
    if (tabs.isEmpty) return null;
    return PanelSaved(tabs, ((j['active'] as int?) ?? 0).clamp(0, tabs.length - 1), view: j['view'] as String?);
  }
}

/// Settings, bookmarks and panel state, in one JSON file.
class Store extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  int seed = themeColors.first;
  String base = 'paper';
  String accent = 'amber';
  String language = 'system';

  PanelLayout layout = PanelLayout.auto;
  bool foldersFirst = true;
  bool showHidden = false;
  bool thumbnails = false;
  bool table = Platform.isWindows;
  bool compact = true;
  bool showParent = true;
  bool confirmDelete = true;
  bool showFreeSpace = true;
  bool driveBar = true;

  /// Thumbnail grid (TC Ctrl+Shift+F1); wins over [table].
  bool grid = false;
  double fontScale = 1.0;

  final List<Bookmark> bookmarks = [];
  final List<Conn> conns = [];

  /// Microsoft app (client) ID for OneDrive; the build can bake one in.
  /// Ncommander's own registration in Microsoft Entra (public client, no secret).
  static const _oneDriveApp = 'b77159ec-a8e2-40f0-abc2-ba0525f04ac4';
  String onedriveClientId = _oneDriveApp;

  Conn? conn(String id) => conns.where((c) => c.id == id).firstOrNull ?? zips[id];

  /// Archives open in panels (session only).
  final Map<String, Conn> zips = {};

  /// "zip://<id>" root for browsing the archive at [zipPath] like a folder.
  String zipRoot(String zipPath) {
    final id = 'z${zipPath.hashCode.toUnsigned(32).toRadixString(36)}${zipPath.length}';
    zips[id] ??= Conn(id: id, type: ConnType.zip, name: zipPath.substring(zipPath.lastIndexOf('/') + 1), host: zipPath);
    return 'zip://$id';
  }
  PanelSaved? left, right;
  int activePanel = 0;

  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/ncommander.json');
      if (await _file!.exists()) {
        fromJson(jsonDecode(await _file!.readAsString()) as Map<String, dynamic>);
        final legacy = await _openAll();
        // Passwords left in clear text by an older version get sealed now.
        if (legacy) await save(notify: false);
      }
    } catch (_) {
      try {
        if (_file != null && _file!.existsSync()) await _file!.copy('${_file!.path}.bak');
      } catch (_) {}
    }
    setLanguage(language);
  }

  T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.firstWhere((v) => v.name == name, orElse: () => fallback);

  void fromJson(Map<String, dynamic> j) {
    final s = Map<String, dynamic>.from((j['settings'] as Map?) ?? {});
    themeMode = _enum(ThemeMode.values, s['theme'], ThemeMode.system);
    seed = s['seed'] ?? seed;
    final old = s['themeId'] as String? ??
        switch (seed) {
          0xFF0E7C66 => 'forest',
          0xFF6750A4 || 0xFF3F51B5 => 'dusk',
          0xFF2B5CE6 || 0xFF00838F => 'ocean',
          0xFF5D6B7A => 'graphite',
          _ => 'amber',
        };
    final (b0, a0) = migrateTheme(old);
    base = s['base'] ?? b0;
    accent = s['accent'] ?? a0;
    language = s['lang'] ?? 'system';
    layout = _enum(PanelLayout.values, s['layout'], PanelLayout.auto);
    foldersFirst = s['foldersFirst'] ?? true;
    showHidden = s['hidden'] ?? false;
    thumbnails = s['thumbs2'] ?? false;
    table = s['compactView'] ?? Platform.isWindows;
    compact = s['compact'] ?? true;
    showParent = s['parent'] ?? true;
    confirmDelete = s['confirmDel'] ?? true;
    showFreeSpace = s['free'] ?? true;
    driveBar = s['drives'] ?? true;
    grid = s['grid'] ?? false;
    fontScale = ((s['font'] as num?)?.toDouble() ?? 1.0).clamp(0.85, 1.25);
    bookmarks
      ..clear()
      ..addAll(((j['bookmarks'] as List?) ?? [])
          .whereType<Map>()
          .map((b) => Bookmark(b['path'] as String, (b['name'] as String?) ?? '')));
    conns
      ..clear()
      ..addAll(((j['conns'] as List?) ?? []).whereType<Map>().map(Conn.fromJson).whereType<Conn>());
    final od = j['onedriveClientId'];
    // The built-in ID wins over anything pasted earlier.
    if (_oneDriveApp.isEmpty && od is String && od.isNotEmpty) onedriveClientId = od;
    final m = j['master'];
    masterSalt = m is Map ? m['salt'] as String? : null;
    masterCheck = m is Map ? m['check'] as String? : null;
    left = PanelSaved.fromJson(j['left']);
    right = PanelSaved.fromJson(j['right']);
    activePanel = ((j['activePanel'] as int?) ?? 0).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'settings': {
          'theme': themeMode.name,
          'seed': seed,
          'base': base,
          'accent': accent,
          'lang': language,
          'layout': layout.name,
          'foldersFirst': foldersFirst,
          'hidden': showHidden,
          'thumbs2': thumbnails,
          'compactView': table,
          'compact': compact,
          'parent': showParent,
          'confirmDel': confirmDelete,
          'free': showFreeSpace,
          'drives': driveBar,
          'grid': grid,
          'font': fontScale,
        },
        'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
        'conns': conns.map((c) => c.toJson()).toList(),
        'onedriveClientId': onedriveClientId,
        if (masterOn) 'master': {'salt': masterSalt, 'check': masterCheck},
        if (left != null) 'left': left!.toJson(),
        if (right != null) 'right': right!.toJson(),
        'activePanel': activePanel,
      };

  bool _saving = false, _again = false;

  /// Saves and notifies; rapid calls collapse into one write.
  Future<void> save({bool notify = true}) async {
    setLanguage(language);
    if (notify) notifyListeners();
    final f = _file;
    if (f == null) return;
    if (_saving) {
      _again = true;
      return;
    }
    _saving = true;
    try {
      do {
        _again = false;
        await _sealAll();
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(toJson()));
        await tmp.rename(f.path);
      } while (_again);
    } catch (_) {
    } finally {
      _saving = false;
    }
  }

  // ---------------------------------------------------------------- secrets

  String? masterSalt, masterCheck;
  SecretKey? _master;
  bool get masterOn => masterSalt != null && masterCheck != null;
  bool get unlocked => !masterOn || _master != null;

  /// Asks the user for the master password (set by the UI); null = cancelled.
  Future<String?> Function({bool wrong})? askMaster;

  /// Opens the sealed secrets; true if clear-text ones from an old file were found.
  Future<bool> _openAll() async {
    var legacy = false;
    for (final c in conns) {
      if (c.sealedPassword.isNotEmpty) {
        final o = await openSecret(c.sealedPassword);
        c.password = o.plain ?? '';
        c._fromPwd = o.plain;
        c.lockedPwd = o.locked;
      } else if (c.password.isNotEmpty) {
        legacy = true;
      }
      if (c.sealedToken.isNotEmpty) {
        final o = await openSecret(c.sealedToken);
        c.token = o.plain ?? '';
        c._fromTok = o.plain;
        c.lockedTok = o.locked;
      } else if (c.token.isNotEmpty) {
        legacy = true;
      }
    }
    return legacy;
  }

  Future<void> _sealAll() async {
    // With a master password set but not entered, new values can't be sealed yet.
    if (masterOn && _master == null) return;
    final key = masterOn ? _master : null;
    for (final c in conns) {
      try {
        if (c.lockedPwd == null && c.password != c._fromPwd) {
          c.sealedPassword = await sealSecret(c.password, master: key);
          c._fromPwd = c.password;
        }
        if (c.lockedTok == null && c.token != c._fromTok) {
          c.sealedToken = await sealSecret(c.token, master: key);
          c._fromTok = c.token;
        }
      } catch (_) {}
    }
  }

  /// Asks for the master password once per session; false if cancelled.
  Future<bool> ensureUnlocked() async {
    if (unlocked) return true;
    final ask = askMaster;
    if (ask == null) return false;
    var wrong = false;
    while (true) {
      final pw = await ask(wrong: wrong);
      if (pw == null) return false;
      final key = await deriveKey(pw, base64.decode(masterSalt!));
      if (await verifyCheck(key, masterCheck!)) {
        _master = key;
        for (final c in conns) {
          if (c.lockedPwd != null) {
            c.password = await openLocked(key, c.lockedPwd!) ?? '';
            c._fromPwd = c.password;
            c.lockedPwd = null;
          }
          if (c.lockedTok != null) {
            c.token = await openLocked(key, c.lockedTok!) ?? '';
            c._fromTok = c.token;
            c.lockedTok = null;
          }
        }
        return true;
      }
      wrong = true;
    }
  }

  /// Turns the master password on (or changes it): everything is re-sealed with it.
  Future<bool> setMaster(String pw) async {
    if (!await ensureUnlocked()) return false;
    final salt = randomBytes(16);
    final key = await deriveKey(pw, salt);
    masterSalt = base64.encode(salt);
    masterCheck = await makeCheck(key);
    _master = key;
    for (final c in conns) {
      c._fromPwd = null;
      c._fromTok = null;
    }
    await save();
    return true;
  }

  Future<bool> removeMaster() async {
    if (!await ensureUnlocked()) return false;
    masterSalt = null;
    masterCheck = null;
    _master = null;
    for (final c in conns) {
      c._fromPwd = null;
      c._fromTok = null;
    }
    await save();
    return true;
  }

  bool isBookmarked(String path) => bookmarks.any((b) => b.path == path);

  void toggleBookmark(String path, String name) {
    if (isBookmarked(path)) {
      bookmarks.removeWhere((b) => b.path == path);
    } else {
      bookmarks.add(Bookmark(path, name));
    }
    save();
  }
}

final store = Store();

String layoutLabel(PanelLayout l) => switch (l) {
      PanelLayout.auto => tr('Automat', 'Automatic'),
      PanelLayout.sideBySide => tr('Alăturate', 'Side by side'),
      PanelLayout.stacked => tr('Una sub alta', 'Stacked'),
    };
