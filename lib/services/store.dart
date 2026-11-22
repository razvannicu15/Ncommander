import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/i18n.dart';
import '../models/entry.dart';

enum PanelLayout { auto, sideBySide, stacked }

/// Theme colours offered in Settings (no pink unless asked for).
const themeColors = <int>[0xFFD9822B, 0xFF2B5CE6, 0xFF0E7C66, 0xFF3F51B5, 0xFF6750A4, 0xFF00838F, 0xFFB3261E, 0xFF5D6B7A];

enum ConnType { ftp, gdrive, onedrive }

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

  String get root => '${type.name}://$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'host': host,
        'port': port,
        'user': user,
        'password': password,
        'tls': tls,
        'folder': folder,
        'account': account,
        'token': token,
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
      token: (j['token'] as String?) ?? '',
    );
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
  PanelSaved(this.tabs, this.active);
  final List<TabState> tabs;
  final int active;
  Map<String, dynamic> toJson() => {'tabs': tabs.map((t) => t.toJson()).toList(), 'active': active};
  static PanelSaved? fromJson(Object? j) {
    if (j is! Map) return null;
    final tabs = ((j['tabs'] as List?) ?? []).whereType<Map>().map(TabState.fromJson).toList();
    if (tabs.isEmpty) return null;
    return PanelSaved(tabs, ((j['active'] as int?) ?? 0).clamp(0, tabs.length - 1));
  }
}

/// Settings, bookmarks and panel state, in one JSON file.
class Store extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  int seed = themeColors.first;
  String themeId = 'amber';
  String language = 'system';

  PanelLayout layout = PanelLayout.auto;
  bool foldersFirst = true;
  bool showHidden = false;
  bool thumbnails = false;
  bool table = false;
  bool compact = true;
  bool showParent = true;
  bool confirmDelete = true;
  bool showFreeSpace = true;
  double fontScale = 1.0;

  final List<Bookmark> bookmarks = [];
  final List<Conn> conns = [];

  /// Microsoft app (client) ID for OneDrive; the build can bake one in.
  /// Ncommander's own registration in Microsoft Entra (public client, no secret).
  static const _oneDriveApp = 'b77159ec-a8e2-40f0-abc2-ba0525f04ac4';
  String onedriveClientId = _oneDriveApp;

  Conn? conn(String id) => conns.where((c) => c.id == id).firstOrNull;
  PanelSaved? left, right;
  int activePanel = 0;

  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/ncommander.json');
      if (await _file!.exists()) {
        fromJson(jsonDecode(await _file!.readAsString()) as Map<String, dynamic>);
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
    themeId = s['themeId'] ??
        switch (seed) {
          0xFF0E7C66 => 'forest',
          0xFF6750A4 || 0xFF3F51B5 => 'dusk',
          0xFF2B5CE6 || 0xFF00838F => 'ocean',
          0xFF5D6B7A => 'graphite',
          _ => 'amber',
        };
    language = s['lang'] ?? 'system';
    layout = _enum(PanelLayout.values, s['layout'], PanelLayout.auto);
    foldersFirst = s['foldersFirst'] ?? true;
    showHidden = s['hidden'] ?? false;
    thumbnails = s['thumbs2'] ?? false;
    table = s['compactView'] ?? false;
    compact = s['compact'] ?? true;
    showParent = s['parent'] ?? true;
    confirmDelete = s['confirmDel'] ?? true;
    showFreeSpace = s['free'] ?? true;
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
    left = PanelSaved.fromJson(j['left']);
    right = PanelSaved.fromJson(j['right']);
    activePanel = ((j['activePanel'] as int?) ?? 0).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'settings': {
          'theme': themeMode.name,
          'seed': seed,
          'themeId': themeId,
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
          'font': fontScale,
        },
        'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
        'conns': conns.map((c) => c.toJson()).toList(),
        'onedriveClientId': onedriveClientId,
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
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(toJson()));
        await tmp.rename(f.path);
      } while (_again);
    } catch (_) {
    } finally {
      _saving = false;
    }
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
