import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'http.dart';
import 'native.dart';
import 'store.dart';
import 'vfs.dart';

const _graph = 'https://graph.microsoft.com/v1.0';
const _login = 'https://login.microsoftonline.com/common/oauth2/v2.0';
const redirectUri = 'ncommander://auth';
const _scope = 'Files.ReadWrite offline_access';

/// OneDrive (personal or work) through Microsoft Graph, addressed by path.
class OneDriveVfs extends Vfs {
  OneDriveVfs(super.conn);

  String? _token;
  DateTime _expires = DateTime(0);

  Future<String> _getToken({bool fresh = false}) async {
    if (!fresh && _token != null && DateTime.now().isBefore(_expires)) return _token!;
    final r = await Http.send('POST', Uri.parse('$_login/token'), form: {
      'client_id': store.onedriveClientId,
      'grant_type': 'refresh_token',
      'refresh_token': conn.token,
      'scope': _scope,
    });
    if (!r.ok) {
      throw RemoteException(r.status == 400
          ? tr('Sesiunea OneDrive a expirat — adaugă din nou contul', 'OneDrive session expired — add the account again')
          : r.error);
    }
    final j = r.json;
    _token = j['access_token'] as String;
    _expires = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?)?.toInt() ?? 3600) - 120));
    final rt = j['refresh_token'];
    if (rt is String && rt != conn.token) {
      conn.token = rt;
      store.save(notify: false);
    }
    return _token!;
  }

  Future<HttpResult> _req(String method, String url, {Object? json}) async {
    for (var i = 0; i < 2; i++) {
      final t = await _getToken(fresh: i > 0);
      final r = await Http.send(method, Uri.parse(url), headers: {'Authorization': 'Bearer $t'}, json: json);
      if (r.status == 401 && i == 0) continue;
      if (!r.ok) throw RemoteException(r.error, status: r.status);
      return r;
    }
    throw RemoteException('OneDrive: 401');
  }

  /// "/me/drive/root" or "/me/drive/root:/a%20b/c:"
  String _item(String path) {
    final rel = relOf(path);
    if (rel.isEmpty) return '$_graph/me/drive/root';
    final enc = rel.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent).join('/');
    return '$_graph/me/drive/root:/$enc:';
  }

  Entry _entry(String dir, Map f) {
    final name = f['name'] as String? ?? '?';
    final isDir = f['folder'] != null || f['package'] != null;
    return Entry(
      path: join(dir, name),
      name: name,
      isDir: isDir,
      size: isDir ? 0 : (f['size'] as num?)?.toInt() ?? 0,
      modified: DateTime.tryParse('${f['lastModifiedDateTime']}')?.toLocal() ?? DateTime(1970),
      id: f['id'] as String?,
      mime: (f['file'] as Map?)?['mimeType'] as String?,
    );
  }

  static const _select = r'$select=id,name,size,folder,file,package,lastModifiedDateTime';

  @override
  Future<List<Entry>> list(String path) async {
    final out = <Entry>[];
    final base = _item(path);
    String? url = '$base/children?\$top=999&$_select';
    while (url != null) {
      final r = await _req('GET', url);
      for (final f in (r.json['value'] as List?) ?? []) {
        out.add(_entry(path, f as Map));
      }
      url = r.json['@odata.nextLink'] as String?;
    }
    return out;
  }

  @override
  Future<Entry?> find(String dir, String name) async {
    try {
      final r = await _req('GET', '${_item(join(dir, name))}?$_select');
      return _entry(dir, r.json);
    } on RemoteException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<String> _idOf(Entry e) async {
    if (e.id != null) return e.id!;
    final r = await _req('GET', '${_item(e.path)}?\$select=id');
    return r.json['id'] as String;
  }

  @override
  Future<String> mkdir(String dir, String name) async {
    await _req('POST', '${_item(dir)}/children', json: {
      'name': name,
      'folder': <String, dynamic>{},
      '@microsoft.graph.conflictBehavior': 'fail',
    });
    return join(dir, name);
  }

  @override
  Future<void> delete(Entry e) async {
    // OneDrive keeps deleted items in its recycle bin.
    await _req('DELETE', '$_graph/me/drive/items/${await _idOf(e)}');
  }

  @override
  Future<void> rename(Entry e, String newName) async {
    await _req('PATCH', '$_graph/me/drive/items/${await _idOf(e)}', json: {'name': newName});
  }

  @override
  Future<void> download(Entry e, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    final id = await _idOf(e);
    for (var i = 0; i < 2; i++) {
      final t = await _getToken(fresh: i > 0);
      try {
        await Http.download(Uri.parse('$_graph/me/drive/items/$id/content'), {'Authorization': 'Bearer $t'}, localPath, onBytes, cancelled);
        return;
      } on RemoteException catch (err) {
        if (i == 0 && err.status == 401) continue;
        rethrow;
      }
    }
  }

  @override
  Future<void> upload(String localPath, String dir, String name, OnBytes onBytes, bool Function() cancelled) async {
    final f = File(localPath);
    final size = await f.length();
    final target = _item(join(dir, name));
    if (size == 0) {
      final t = await _getToken();
      final r = await Http.send('PUT', Uri.parse('$target/content'), headers: {'Authorization': 'Bearer $t'}, bytes: const []);
      if (!r.ok) throw RemoteException(r.error, status: r.status);
      return;
    }
    final s = await _req('POST', '$target/createUploadSession', json: {
      'item': {'@microsoft.graph.conflictBehavior': 'replace'},
    });
    final url = s.json['uploadUrl'] as String?;
    if (url == null) throw RemoteException('OneDrive: upload session');
    // Chunks must be multiples of 320 KiB; 10 MiB = 32 × 320 KiB.
    const chunk = 10 * 1024 * 1024;
    final raf = await f.open();
    try {
      var start = 0;
      while (start < size) {
        final len = min(chunk, size - start);
        final r = await Http.putFileRange('PUT', Uri.parse(url), {'Content-Range': 'bytes $start-${start + len - 1}/$size'}, raf, start, len,
            onBytes, cancelled);
        if (!r.ok) {
          // Tell the service to drop the half-done upload.
          unawaited(Http.send('DELETE', Uri.parse(url)).then((_) {}, onError: (_) {}));
          throw RemoteException(r.error, status: r.status);
        }
        start += len;
      }
    } on JobCancelled {
      unawaited(Http.send('DELETE', Uri.parse(url)).then((_) {}, onError: (_) {}));
      rethrow;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<(int, int)?> space() async {
    final r = await _req('GET', '$_graph/me/drive?\$select=quota');
    final q = r.json['quota'] as Map?;
    final total = (q?['total'] as num?)?.toInt();
    final free = (q?['remaining'] as num?)?.toInt();
    if (total == null || free == null) return null;
    return (total, free);
  }
}

String _rand(int n) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

/// Sign-in in the browser (OAuth code + PKCE); returns (account name, refresh token).
Future<(String, String)> connectOneDrive(String clientId) async {
  final verifier = _rand(64);
  final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
  final state = _rand(24);
  final url = Uri.parse('$_login/authorize').replace(queryParameters: {
    'client_id': clientId,
    'response_type': 'code',
    'redirect_uri': redirectUri,
    'response_mode': 'query',
    'scope': _scope,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
    'state': state,
    'prompt': 'select_account',
  });
  final back = Native.redirects.first.timeout(const Duration(minutes: 5));
  await Native.openUrl(url.toString());
  final uri = Uri.parse(await back);
  final q = uri.queryParameters;
  if (q['error'] != null) throw RemoteException(q['error_description'] ?? q['error']!);
  if (q['state'] != state || q['code'] == null) throw RemoteException(tr('Autentificare anulată', 'Sign-in cancelled'));
  final r = await Http.send('POST', Uri.parse('$_login/token'), form: {
    'client_id': clientId,
    'grant_type': 'authorization_code',
    'code': q['code']!,
    'redirect_uri': redirectUri,
    'code_verifier': verifier,
    'scope': _scope,
  });
  if (!r.ok) throw RemoteException(r.error);
  final access = r.json['access_token'] as String;
  final refresh = r.json['refresh_token'] as String? ?? '';
  final me = await Http.send('GET', Uri.parse('$_graph/me/drive?\$select=owner,driveType'), headers: {'Authorization': 'Bearer $access'});
  final owner = ((me.json['owner'] as Map?)?['user'] as Map?)?['displayName'] as String?;
  return (owner ?? 'OneDrive', refresh);
}
