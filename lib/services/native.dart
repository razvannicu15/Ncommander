import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'win.dart';

class Volume {
  Volume({required this.path, required this.label, required this.removable, required this.primary, this.total = 0, this.free = 0});
  final String path;
  final String label;
  final bool removable;
  final bool primary;
  int total;
  int free;
}

/// Bridge to MainActivity.kt: storage access, volumes, intents, thumbnails.
class Native {
  static const _ch = MethodChannel('ncommander/native');

  static Future<T?> _call<T>(String m, [Object? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } catch (_) {
      return null;
    }
  }

  /// "All files access" on Android 11+, storage permission before.
  static Future<bool> hasAccess() async => (await _call<bool>('hasAccess')) ?? true;
  static Future<void> requestAccess() => _call('requestAccess');

  /// Wallpaper accent on Android 12+, otherwise null.
  static Future<Color?> systemAccent() async {
    if (Platform.isWindows) {
      final c = await winAccent();
      return c == null ? null : Color(c);
    }
    final v = await _call<int>('systemAccent');
    return v == null ? null : Color(v);
  }

  static Future<List<Volume>> volumes() async {
    if (Platform.isWindows) return winVolumes();
    final r = await _call<List<Object?>>('volumes');
    if (r == null) return [];
    return [
      for (final v in r.cast<Map<Object?, Object?>>())
        Volume(
          path: v['path'] as String,
          label: v['label'] as String? ?? '',
          removable: v['removable'] == true,
          primary: v['primary'] == true,
          total: (v['total'] as num?)?.toInt() ?? 0,
          free: (v['free'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// [total, free] bytes of the volume holding [path].
  static Future<(int, int)> space(String path) async {
    if (Platform.isWindows) return winSpace(path);
    final r = await _call<List<Object?>>('space', path);
    if (r == null || r.length < 2) return (0, 0);
    return ((r[0] as num).toInt(), (r[1] as num).toInt());
  }

  /// Opens with the default app; false when no app can open it.
  static Future<bool> open(String path, String mime, {bool chooser = false}) async => Platform.isWindows
      ? winOpen(path, chooser: chooser)
      : (await _call<bool>('open', {'path': path, 'mime': mime, 'chooser': chooser})) ?? false;

  static Future<void> share(List<String> paths, String mime) =>
      Platform.isWindows ? winOpen(paths.first, chooser: true) : _call('share', {'paths': paths, 'mime': mime});

  static Future<void> scan(List<String> paths) => _call('scan', paths);

  /// Small preview for videos, audio covers, PDFs and APK icons.
  static Future<Uint8List?> thumb(String path, String kind, int size) =>
      _call<Uint8List>('thumb', {'path': path, 'kind': kind, 'size': size});

  static Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));

  static final _redirects = StreamController<String>.broadcast();

  /// "ncommander://auth?..." links coming back from a browser sign-in.
  static Stream<String> get redirects => _redirects.stream;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'redirect' && call.arguments is String) _redirects.add(call.arguments as String);
      return null;
    });
  }

  static Future<void> openUrl(String url) => Platform.isWindows ? winOpenUrl(url) : _call('openUrl', url);

  /// Google Drive access token. With [interactive] the account picker /
  /// consent screen may show; without it null means "needs the user".
  static Future<String?> googleToken(String account, {required bool interactive}) async {
    try {
      return await _ch.invokeMethod<String>('googleToken', {'account': account, 'interactive': interactive});
    } on PlatformException catch (e) {
      if (!interactive) return null;
      throw Exception(e.message ?? e.code);
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the phone's Google account chooser; returns the e-mail or null.
  static Future<String?> googlePickAccount() async {
    try {
      return await _ch.invokeMethod<String>('googlePickAccount');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> googleClearToken(String token) => _call('googleClearToken', token);
}
