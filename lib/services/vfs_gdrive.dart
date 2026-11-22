import 'dart:io';

import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'http.dart';
import 'native.dart';
import 'vfs.dart';

const _folder = 'application/vnd.google-apps.folder';
const _api = 'https://www.googleapis.com/drive/v3';
const _upload = 'https://www.googleapis.com/upload/drive/v3';

/// Google Docs/Sheets/Slides have no bytes of their own: exported on download.
const _exports = {
  'application/vnd.google-apps.document': ('application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'docx'),
  'application/vnd.google-apps.spreadsheet': ('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'xlsx'),
  'application/vnd.google-apps.presentation': ('application/vnd.openxmlformats-officedocument.presentationml.presentation', 'pptx'),
  'application/vnd.google-apps.drawing': ('image/png', 'png'),
};

/// Google Drive ("My Drive") as a remote location. Drive works with IDs, so
/// paths seen while browsing are mapped to IDs here.
class GDriveVfs extends Vfs {
  GDriveVfs(super.conn);

  String? _token;
  final _ids = <String, String>{};

  /// Names may contain "/", which would break paths.
  static String seg(String name) => name.replaceAll('/', '∕');
  static String unseg(String s) => s.replaceAll('∕', '/');

  Future<String> _getToken({bool fresh = false}) async {
    if (fresh && _token != null) {
      await Native.googleClearToken(_token!);
      _token = null;
    }
    _token ??= await Native.googleToken(conn.account, interactive: false) ??
        await Native.googleToken(conn.account, interactive: true);
    if (_token == null) throw RemoteException(tr('Autentificare Google anulată', 'Google sign-in cancelled'));
    return _token!;
  }

  /// Runs a request with the token, refreshing it once on 401.
  Future<HttpResult> _req(String method, String url, {Object? json, Map<String, String> headers = const {}}) async {
    for (var i = 0; i < 2; i++) {
      final t = await _getToken(fresh: i > 0);
      final r = await Http.send(method, Uri.parse(url), headers: {'Authorization': 'Bearer $t', ...headers}, json: json);
      if (r.status == 401 && i == 0) continue;
      if (!r.ok) throw RemoteException(r.error);
      return r;
    }
    throw RemoteException('Google: 401');
  }

  static String _q(String s) => s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  Future<String> _idOf(String path) async {
    if (path == root) return 'root';
    final hit = _ids[path];
    if (hit != null) return hit;
    final pid = await _idOf(parentOf(path));
    final name = unseg(nameOf(path));
    final q = "name='${_q(name)}' and '$pid' in parents and trashed=false";
    final r = await _req('GET', '$_api/files?q=${Uri.encodeQueryComponent(q)}&fields=files(id,mimeType)&pageSize=10');
    final files = (r.json['files'] as List?) ?? [];
    if (files.isEmpty) throw RemoteException(tr('Nu există: $name', 'Not found: $name'));
    return _ids[path] = (files.first as Map)['id'] as String;
  }

  Entry _entry(String dir, Map f) {
    final mime = f['mimeType'] as String? ?? '';
    final name = f['name'] as String? ?? '?';
    final p = join(dir, seg(name));
    final id = f['id'] as String;
    _ids[p] = id;
    final isDir = mime == _folder;
    return Entry(
      path: p,
      name: seg(name),
      isDir: isDir,
      size: int.tryParse('${f['size'] ?? 0}') ?? 0,
      modified: DateTime.tryParse('${f['modifiedTime']}')?.toLocal() ?? DateTime(1970),
      id: id,
      mime: mime,
    );
  }

  @override
  Future<List<Entry>> list(String path) async {
    final id = await _idOf(path);
    final q = "'$id' in parents and trashed=false";
    final out = <Entry>[];
    String? page;
    do {
      final r = await _req('GET',
          '$_api/files?q=${Uri.encodeQueryComponent(q)}&pageSize=1000&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime)${page == null ? '' : '&pageToken=$page'}');
      for (final f in (r.json['files'] as List?) ?? []) {
        final m = f as Map;
        if (m['mimeType'] == 'application/vnd.google-apps.shortcut') continue;
        out.add(_entry(path, m));
      }
      page = r.json['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  @override
  Future<Entry?> find(String dir, String name) async {
    final pid = await _idOf(dir);
    final q = "name='${_q(unseg(name))}' and '$pid' in parents and trashed=false";
    final r = await _req('GET', '$_api/files?q=${Uri.encodeQueryComponent(q)}&fields=files(id,name,mimeType,size,modifiedTime)&pageSize=10');
    final files = (r.json['files'] as List?) ?? [];
    if (files.isEmpty) return null;
    return _entry(dir, files.first as Map);
  }

  @override
  Future<String> mkdir(String dir, String name) async {
    final pid = await _idOf(dir);
    final r = await _req('POST', '$_api/files?fields=id', json: {
      'name': unseg(name),
      'mimeType': _folder,
      'parents': [pid],
    });
    final p = join(dir, seg(name));
    _ids[p] = r.json['id'] as String;
    return p;
  }

  @override
  Future<void> delete(Entry e) async {
    final id = e.id ?? await _idOf(e.path);
    // To the Drive bin, recoverable for 30 days.
    await _req('PATCH', '$_api/files/$id', json: {'trashed': true});
    _ids.removeWhere((k, _) => isInside(k, e.path));
  }

  @override
  Future<void> rename(Entry e, String newName) async {
    final id = e.id ?? await _idOf(e.path);
    await _req('PATCH', '$_api/files/$id', json: {'name': unseg(newName)});
    _ids.removeWhere((k, _) => isInside(k, e.path));
  }

  @override
  String localName(Entry e) {
    final ex = _exports[e.mime];
    if (ex != null) return '${unseg(e.name)}.${ex.$2}';
    if ((e.mime ?? '').startsWith('application/vnd.google-apps.')) return '${unseg(e.name)}.pdf';
    return unseg(e.name);
  }

  @override
  Future<void> download(Entry e, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    final id = e.id ?? await _idOf(e.path);
    final mime = e.mime ?? '';
    String url;
    if (mime.startsWith('application/vnd.google-apps.')) {
      final to = _exports[mime]?.$1 ?? 'application/pdf';
      url = '$_api/files/$id/export?mimeType=${Uri.encodeQueryComponent(to)}';
    } else {
      url = '$_api/files/$id?alt=media';
    }
    for (var i = 0; i < 2; i++) {
      final t = await _getToken(fresh: i > 0);
      try {
        await Http.download(Uri.parse(url), {'Authorization': 'Bearer $t'}, localPath, onBytes, cancelled);
        return;
      } on RemoteException catch (err) {
        if (i == 0 && err.status == 401) continue;
        rethrow;
      }
    }
  }

  @override
  Future<void> upload(String localPath, String dir, String name, OnBytes onBytes, bool Function() cancelled) async {
    final pid = await _idOf(dir);
    final existing = await find(dir, name);
    final f = File(localPath);
    final size = await f.length();
    // Resumable session: one PUT with the whole file, streamed from disk.
    final HttpResult start;
    if (existing != null && !existing.isDir) {
      start = await _req('PATCH', '$_upload/files/${existing.id}?uploadType=resumable',
          json: <String, dynamic>{}, headers: {'X-Upload-Content-Length': '$size'});
    } else {
      start = await _req('POST', '$_upload/files?uploadType=resumable', json: {
        'name': unseg(name),
        'parents': [pid],
      }, headers: {
        'X-Upload-Content-Length': '$size'
      });
    }
    final session = start.headers.value(HttpHeaders.locationHeader);
    if (session == null) throw RemoteException('Google: upload session');
    final raf = await f.open();
    try {
      final r = await Http.putFileRange('PUT', Uri.parse(session), {'Content-Type': 'application/octet-stream'}, raf, 0, size, onBytes, cancelled);
      if (!r.ok) throw RemoteException(r.error);
      final id = r.json['id'];
      if (id is String) _ids[join(dir, seg(name))] = id;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<(int, int)?> space() async {
    final r = await _req('GET', '$_api/about?fields=storageQuota(limit,usage)');
    final q = r.json['storageQuota'] as Map?;
    final limit = int.tryParse('${q?['limit'] ?? ''}');
    final usage = int.tryParse('${q?['usage'] ?? ''}') ?? 0;
    if (limit == null) return null;
    return (limit, limit - usage);
  }
}

/// Signs in with a Google account picked on the phone; returns its e-mail.
Future<String> connectGoogle() async {
  final token = await Native.googleToken('', interactive: true);
  if (token == null) throw RemoteException(tr('Autentificare Google anulată', 'Google sign-in cancelled'));
  final r = await Http.send('GET', Uri.parse('$_api/about?fields=user(emailAddress,displayName)'), headers: {'Authorization': 'Bearer $token'});
  if (!r.ok) throw RemoteException(r.error);
  final u = r.json['user'] as Map?;
  return (u?['emailAddress'] as String?) ?? (u?['displayName'] as String?) ?? 'Google';
}
