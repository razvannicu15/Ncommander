import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fs.dart';
import 'vfs.dart';

class HttpResult {
  HttpResult(this.status, this.body, this.headers);
  final int status;
  final String body;
  final HttpHeaders headers;

  bool get ok => status >= 200 && status < 300;

  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  /// Message from a Google / Microsoft error body.
  String get error {
    final j = json['error'];
    if (j is Map) return '${j['message'] ?? j['code'] ?? status}';
    if (j is String) return '${json['error_description'] ?? j}';
    return 'HTTP $status';
  }
}

/// Small HTTP helper on dart:io (streams files, reports progress).
class Http {
  static final HttpClient _c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30);

  static Future<HttpResult> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? json,
    Map<String, String>? form,
    List<int>? bytes,
  }) async {
    final req = await _c.openUrl(method, url);
    headers.forEach(req.headers.set);
    List<int>? data = bytes;
    if (json != null) {
      req.headers.contentType = ContentType.json;
      data = utf8.encode(jsonEncode(json));
    } else if (form != null) {
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      data = utf8.encode(form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
    }
    if (data != null) {
      req.contentLength = data.length;
      req.add(data);
    } else if (method != 'GET' && method != 'DELETE') {
      req.contentLength = 0;
    }
    final res = await req.close().timeout(const Duration(seconds: 60));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 60));
    return HttpResult(res.statusCode, body, res.headers);
  }

  /// GET into a file. Redirects are followed by hand so the bearer token is
  /// not sent to the storage host (pre-signed URLs reject it).
  static Future<void> download(Uri url, Map<String, String> headers, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    var u = url;
    var h = headers;
    for (var hop = 0; hop < 5; hop++) {
      final req = await _c.getUrl(u);
      req.followRedirects = false;
      h.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (loc == null) throw RemoteException('HTTP ${res.statusCode}');
        u = u.resolve(loc);
        h = const {};
        continue;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await res.transform(utf8.decoder).join();
        throw RemoteException(HttpResult(res.statusCode, body, res.headers).error, status: res.statusCode);
      }
      final out = await File(localPath).open(mode: FileMode.write);
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          if (cancelled()) throw JobCancelled();
          await out.writeFrom(chunk);
          onBytes(chunk.length);
        }
      } finally {
        await out.close();
      }
      return;
    }
    throw RemoteException('HTTP: too many redirects');
  }

  /// PUT / PATCH a byte range of a local file (resumable uploads).
  static Future<HttpResult> putFileRange(
    String method,
    Uri url,
    Map<String, String> headers,
    RandomAccessFile file,
    int start,
    int length,
    OnBytes onBytes,
    bool Function() cancelled,
  ) async {
    final req = await _c.openUrl(method, url);
    headers.forEach(req.headers.set);
    req.contentLength = length;
    await file.setPosition(start);
    var left = length;
    while (left > 0) {
      if (cancelled()) {
        req.abort();
        throw JobCancelled();
      }
      final chunk = await file.read(left < 256 * 1024 ? left : 256 * 1024);
      if (chunk.isEmpty) break;
      req.add(chunk);
      await req.flush();
      left -= chunk.length;
      onBytes(chunk.length);
    }
    final res = await req.close().timeout(const Duration(minutes: 2));
    final body = await res.transform(utf8.decoder).join();
    return HttpResult(res.statusCode, body, res.headers);
  }
}
