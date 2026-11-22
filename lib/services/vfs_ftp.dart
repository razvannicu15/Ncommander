import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'store.dart';
import 'vfs.dart';

class FtpReply {
  FtpReply(this.code, this.text);
  final int code;
  final String text;
  bool get ok => code >= 200 && code < 400;
  @override
  String toString() => '$code $text';
}

/// The control connection went away (idle timeout): reconnect and retry.
class _Dropped implements Exception {
  const _Dropped();
  @override
  String toString() => tr('Serverul a închis conexiunea', 'The server closed the connection');
}

/// The encrypted data channel (PROT P) doesn't work with this server;
/// the caller retries with clear data (PROT C, login still encrypted).
class TlsDataException implements Exception {
  const TlsDataException();
}

/// Line reader over a socket that can be upgraded to TLS mid-way.
class _Wire {
  Socket? _s;
  StreamSubscription<List<int>>? _sub;
  final _buf = <int>[];
  final _lines = Queue<String>();
  Completer<void>? _wait;
  Object? _error;
  bool _closed = false;

  Socket get socket => _s!;

  void attach(Socket s) {
    _s = s;
    _closed = false;
    _sub = s.listen(_data, onError: (Object e) {
      _error = e;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    }, cancelOnError: true);
  }

  void _data(List<int> d) {
    _buf.addAll(d);
    int i;
    while ((i = _buf.indexOf(10)) >= 0) {
      var line = utf8.decode(_buf.sublist(0, i), allowMalformed: true);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _buf.removeRange(0, i + 1);
      _lines.add(line);
    }
    _wake();
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<String> line(Duration timeout) async {
    while (_lines.isEmpty) {
      if (_error != null) throw _error!;
      if (_closed) throw const _Dropped();
      _wait = Completer<void>();
      await _wait!.future.timeout(timeout);
    }
    return _lines.removeFirst();
  }

  /// Hands the raw socket over for a TLS upgrade.
  Socket detach() {
    _sub?.pause();
    return _s!;
  }

  void write(String s) => _s!.add(utf8.encode('$s\r\n'));

  void destroy() {
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      _s?.destroy();
    } catch (_) {}
    _closed = true;
  }
}

/// One data connection (listing or file transfer).
abstract class _Data {
  /// Finishes the TLS handshake for encrypted data; no-op for plain.
  Future<void> start();
  Stream<List<int>> get input;
  Future<void> write(List<int> bytes);

  /// Sends end-of-file (close_notify + FIN) after an upload.
  Future<void> finish();
  void destroy();
}

class _PlainData implements _Data {
  _PlainData(this.s);
  final Socket s;
  @override
  Future<void> start() async {}
  @override
  Stream<List<int>> get input => s;
  @override
  Future<void> write(List<int> bytes) async {
    s.add(bytes);
    await s.flush();
  }

  @override
  Future<void> finish() => s.close();
  @override
  void destroy() => s.destroy();
}

/// Encrypted data on a RawSecureSocket, read and written by hand: the
/// Socket-level TLS upgrade can lose a short listing that the server sends
/// and closes right after the handshake (seen with Pure-FTPd + TLS 1.3).
class _TlsData implements _Data {
  _TlsData(this.raw, this.host, this.badCert);
  RawSocket raw;
  final String host;
  final bool Function(X509Certificate) badCert;
  final _in = StreamController<List<int>>();
  Completer<void>? _writable;
  bool _closed = false;

  @override
  Future<void> start() async {
    final sec = await RawSecureSocket.secure(raw, host: host, onBadCertificate: badCert).timeout(const Duration(seconds: 8));
    raw = sec;
    sec.listen((ev) {
      switch (ev) {
        case RawSocketEvent.read:
          _drain();
        case RawSocketEvent.write:
          final w = _writable;
          _writable = null;
          if (w != null && !w.isCompleted) w.complete();
        case RawSocketEvent.readClosed:
          _drain();
          _end();
        case RawSocketEvent.closed:
          _end();
      }
    }, onError: (Object e) {
      if (!_in.isClosed) _in.addError(e);
      _end();
    }, onDone: _end);
    _drain();
  }

  void _drain() {
    while (true) {
      final d = raw.read();
      if (d == null || d.isEmpty) break;
      if (!_in.isClosed) _in.add(d);
    }
  }

  void _end() {
    if (!_in.isClosed) _in.close();
    final w = _writable;
    _writable = null;
    if (w != null && !w.isCompleted) w.completeError(RemoteException('TLS data closed'));
  }

  @override
  Stream<List<int>> get input => _in.stream;

  @override
  Future<void> write(List<int> bytes) async {
    var off = 0;
    while (off < bytes.length) {
      if (_closed) throw RemoteException('TLS data closed');
      final n = raw.write(bytes, off);
      off += n;
      if (off < bytes.length) {
        _writable = Completer<void>();
        raw.writeEventsEnabled = true;
        await _writable!.future.timeout(const Duration(seconds: 60));
      }
    }
  }

  @override
  Future<void> finish() async {
    await raw.close();
    _closed = true;
  }

  @override
  void destroy() {
    _closed = true;
    try {
      raw.close();
    } catch (_) {}
    _end();
  }
}

/// Minimal FTP / FTPS (explicit or port 990 implicit) client: passive mode,
/// MLSD with LIST fallback, binary transfers with progress.
class FtpClient {
  FtpClient({required this.host, this.port = 21, this.user = '', this.password = '', this.tls = false, this.protectData = true});

  final String host;
  final int port;
  final String user, password;
  final bool tls;

  /// PROT P (encrypted transfers) vs PROT C (only the login encrypted).
  final bool protectData;

  final _w = _Wire();
  bool _mlsd = false;
  bool connected = false;
  static const _timeout = Duration(seconds: 30);

  bool _badCert(X509Certificate _) => true; // home NAS / routers use self-signed certs

  Future<FtpReply> _reply() async {
    final first = await _w.line(_timeout);
    if (first.length < 3) return FtpReply(0, first);
    final code = int.tryParse(first.substring(0, 3)) ?? 0;
    final b = StringBuffer(first.length > 4 ? first.substring(4) : '');
    if (first.length > 3 && first[3] == '-') {
      while (true) {
        final l = await _w.line(_timeout);
        if (l.startsWith('$code ')) {
          b.write('\n${l.substring(4)}');
          break;
        }
        b.write('\n$l');
      }
    }
    return FtpReply(code, b.toString());
  }

  Future<FtpReply> cmd(String c) async {
    _w.write(c);
    return _reply();
  }

  Future<FtpReply> _expect(String c, [List<int> codes = const []]) async {
    final r = await cmd(c);
    if (codes.isEmpty ? !r.ok : !codes.contains(r.code)) {
      throw RemoteException('${c.split(' ').first}: ${r.code} ${r.text.split('\n').first}');
    }
    return r;
  }

  Future<void> connect() async {
    final implicit = tls && port == 990;
    final Socket s = implicit
        ? await SecureSocket.connect(host, port, timeout: const Duration(seconds: 15), onBadCertificate: _badCert)
        : await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    _w.attach(s);
    final hello = await _reply();
    if (hello.code != 220) throw RemoteException('FTP: ${hello.code} ${hello.text}');
    if (tls && !implicit) {
      final r = await cmd('AUTH TLS');
      if (r.code != 234) throw RemoteException(tr('Serverul nu acceptă TLS', 'The server doesn\'t support TLS'));
      final raw = _w.detach();
      final sec = await SecureSocket.secure(raw, host: host, onBadCertificate: _badCert).timeout(const Duration(seconds: 15));
      _w.attach(sec);
    }
    if (tls) {
      await cmd('PBSZ 0');
      await cmd(protectData ? 'PROT P' : 'PROT C');
    }
    final u = user.isEmpty ? 'anonymous' : user;
    var r = await cmd('USER $u');
    if (r.code == 331 || r.code == 332) {
      r = await cmd('PASS ${password.isEmpty && user.isEmpty ? 'anonymous@' : password}');
    }
    if (r.code != 230 && r.code != 202) {
      throw RemoteException(r.code == 530 ? tr('Utilizator sau parolă greșită', 'Wrong user name or password') : 'FTP: ${r.code} ${r.text}');
    }
    await cmd('OPTS UTF8 ON');
    final feat = await cmd('FEAT');
    _mlsd = feat.text.toUpperCase().contains('MLSD');
    await _expect('TYPE I');
    connected = true;
  }

  bool _noEpsv = false;
  static const _dataTimeout = Duration(seconds: 20);

  static bool _private(InternetAddress a) {
    final b = a.rawAddress;
    if (a.type != InternetAddressType.IPv4 || b.length != 4) return false;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168) || b[0] == 127;
  }

  /// Opens a passive data connection: EPSV first, PASV when EPSV is missing
  /// or its port can't be reached (some hosts only open PASV ports).
  Future<_Data> _data() async {
    final ctl = _w.socket.remoteAddress;
    if (!_noEpsv) {
      final e = await cmd('EPSV');
      final m = e.code == 229 ? RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(e.text) : null;
      if (m != null) {
        try {
          return await _open(ctl, int.parse(m.group(1)!), const Duration(seconds: 8));
        } catch (_) {
          _noEpsv = true;
        }
      } else {
        _noEpsv = true;
      }
    }
    final r = await _expect('PASV', [227]);
    final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(r.text);
    if (m == null) throw RemoteException('PASV: ${r.text}');
    final port = int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    final told = InternetAddress('${m.group(1)}.${m.group(2)}.${m.group(3)}.${m.group(4)}');
    // A private address in the reply means NAT: use the server's public address.
    final targets = <InternetAddress>[
      if (!_private(told) || _private(ctl)) told,
      ctl,
    ];
    Object? last;
    for (final a in targets) {
      try {
        return await _open(a, port, const Duration(seconds: 10));
      } catch (e) {
        last = e;
      }
    }
    throw RemoteException(tr('Nu se poate deschide conexiunea de date (PASV)', 'Can\'t open the data connection (PASV)') + (last == null ? '' : ': $last'));
  }

  bool get _encData => tls && protectData;

  Future<_Data> _open(InternetAddress a, int port, Duration timeout) async {
    if (_encData) return _TlsData(await RawSocket.connect(a, port, timeout: timeout), host, _badCert);
    return _PlainData(await Socket.connect(a, port, timeout: timeout));
  }

  /// Runs the data-channel handshake, turning TLS trouble into TlsDataException.
  Future<void> _startData(_Data d) async {
    try {
      await d.start();
    } catch (_) {
      d.destroy();
      if (_encData) throw const TlsDataException();
      rethrow;
    }
  }

  /// After a failed transfer the control connection is out of step: drop it
  /// so the next command starts on a fresh one.
  Future<T> _transfer<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      destroy();
      if (_encData && e is RemoteException && e.message.contains(': ')) {
        // Silence on an encrypted data channel: try clear data next time.
        if (e.message.endsWith(tr('serverul nu trimite date', 'the server sends no data'))) throw const TlsDataException();
      }
      rethrow;
    }
  }

  /// Data stream with a clear error when the server stops sending.
  Stream<List<int>> _guard(Stream<List<int>> s, String what) => s.timeout(_dataTimeout, onTimeout: (sink) {
        sink.addError(RemoteException(tr('$what: serverul nu trimite date', '$what: the server sends no data')));
        sink.close();
      });

  Future<void> cwd(String path) => _expect('CWD $path');

  Future<String> pwd() async {
    final r = await _expect('PWD', [257]);
    final m = RegExp(r'"(.*)"').firstMatch(r.text);
    return m?.group(1)?.replaceAll('""', '"') ?? '/';
  }

  /// Lists [dir]; entry paths are built with [prefix] (the vfs path of [dir]).
  Future<List<Entry>> list(String dir, String prefix) async {
    await cwd(dir);
    final raw = await _dataCommand(_mlsd ? 'MLSD' : 'LIST -a');
    final lines = const LineSplitter().convert(utf8.decode(raw, allowMalformed: true));
    final out = <Entry>[];
    for (final l in lines) {
      final e = _mlsd ? parseMlsd(l, prefix) : parseList(l, prefix);
      if (e != null && e.name != '.' && e.name != '..') out.add(e);
    }
    return out;
  }

  Future<List<int>> _dataCommand(String c) => _transfer(() => _dataCommand0(c));

  Future<List<int>> _dataCommand0(String c) async {
    final d = await _data();
    final sec = _startData(d);
    final r = await cmd(c);
    if (r.code != 150 && r.code != 125) {
      d.destroy();
      sec.ignore();
      throw RemoteException('${c.split(' ').first}: ${r.code} ${r.text.split('\n').first}');
    }
    await sec;
    final bytes = <int>[];
    try {
      await for (final chunk in _guard(d.input, c.split(' ').first)) {
        bytes.addAll(chunk);
      }
    } finally {
      d.destroy();
    }
    final done = await _reply();
    if (!done.ok) throw RemoteException('${c.split(' ').first}: ${done.code} ${done.text}');
    return bytes;
  }

  Future<void> retr(String path, String localPath, OnBytes onBytes, bool Function() cancelled) =>
      _transfer(() => _retr(path, localPath, onBytes, cancelled));

  Future<void> _retr(String path, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    final d = await _data();
    final sec = _startData(d);
    final r = await cmd('RETR $path');
    if (r.code != 150 && r.code != 125) {
      d.destroy();
      sec.ignore();
      throw RemoteException('RETR: ${r.code} ${r.text.split('\n').first}');
    }
    await sec;
    final out = await File(localPath).open(mode: FileMode.write);
    try {
      await for (final chunk in _guard(d.input, 'RETR')) {
        if (cancelled()) {
          d.destroy();
          throw JobCancelled();
        }
        await out.writeFrom(chunk);
        onBytes(chunk.length);
      }
    } finally {
      await out.close();
      d.destroy();
    }
    final done = await _reply();
    if (!done.ok) throw RemoteException('RETR: ${done.code} ${done.text}');
  }

  Future<void> stor(String path, String localPath, OnBytes onBytes, bool Function() cancelled) =>
      _transfer(() => _stor(path, localPath, onBytes, cancelled));

  Future<void> _stor(String path, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    final d = await _data();
    final sec = _startData(d);
    final r = await cmd('STOR $path');
    if (r.code != 150 && r.code != 125) {
      d.destroy();
      sec.ignore();
      throw RemoteException('STOR: ${r.code} ${r.text.split('\n').first}');
    }
    await sec;
    final input = await File(localPath).open();
    try {
      while (true) {
        if (cancelled()) {
          d.destroy();
          throw JobCancelled();
        }
        final chunk = await input.read(256 * 1024);
        if (chunk.isEmpty) break;
        await d.write(chunk);
        onBytes(chunk.length);
      }
      await d.finish();
    } finally {
      await input.close();
    }
    final done = await _reply();
    if (!done.ok) throw RemoteException('STOR: ${done.code} ${done.text}');
  }

  Future<void> mkd(String path) => _expect('MKD $path');
  Future<void> dele(String path) => _expect('DELE $path');
  Future<void> rmd(String path) => _expect('RMD $path');

  Future<void> rename(String from, String to) async {
    await _expect('RNFR $from', [350]);
    await _expect('RNTO $to');
  }

  Future<void> quit() async {
    try {
      _w.write('QUIT');
      await _reply().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _w.destroy();
    connected = false;
  }

  void destroy() {
    _w.destroy();
    connected = false;
  }
}

/// "type=dir;size=0;modify=20261122140500; Photos"
Entry? parseMlsd(String line, String prefix) {
  final sp = line.indexOf(' ');
  if (sp < 0) return null;
  final name = line.substring(sp + 1);
  final facts = <String, String>{};
  for (final f in line.substring(0, sp).split(';')) {
    final i = f.indexOf('=');
    if (i > 0) facts[f.substring(0, i).toLowerCase()] = f.substring(i + 1);
  }
  final type = (facts['type'] ?? '').toLowerCase();
  if (type == 'cdir' || type == 'pdir') return null;
  final dir = type == 'dir';
  DateTime t = DateTime(1970);
  final m = facts['modify'];
  if (m != null && m.length >= 14) {
    t = DateTime.utc(int.parse(m.substring(0, 4)), int.parse(m.substring(4, 6)), int.parse(m.substring(6, 8)),
            int.parse(m.substring(8, 10)), int.parse(m.substring(10, 12)), int.parse(m.substring(12, 14)))
        .toLocal();
  }
  return Entry(
    path: join(prefix, name),
    name: name,
    isDir: dir,
    size: dir ? 0 : int.tryParse(facts['size'] ?? '') ?? 0,
    modified: t,
  );
}

const _months = {'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12};

/// Unix "ls -l" and Windows/IIS "dir" listings.
Entry? parseList(String line, String prefix) {
  final unix = RegExp(r'^([\-dlbcps])[rwxsStT\-]{9}\S*\s+\d+\s+(?:\S+\s+){1,2}(\d+)\s+(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$')
      .firstMatch(line);
  if (unix != null) {
    final kind = unix.group(1)!;
    var name = unix.group(6)!;
    if (kind == 'l') {
      final arrow = name.indexOf(' -> ');
      if (arrow > 0) name = name.substring(0, arrow);
    }
    final mon = _months[unix.group(3)!.toLowerCase()] ?? 1;
    final day = int.parse(unix.group(4)!);
    final tp = unix.group(5)!;
    DateTime t;
    if (tp.contains(':')) {
      final now = DateTime.now();
      final hm = tp.split(':');
      t = DateTime(now.year, mon, day, int.parse(hm[0]), int.parse(hm[1]));
      if (t.isAfter(now.add(const Duration(days: 2)))) t = DateTime(now.year - 1, mon, day, t.hour, t.minute);
    } else {
      t = DateTime(int.parse(tp), mon, day);
    }
    final dir = kind == 'd';
    return Entry(path: join(prefix, name), name: name, isDir: dir, size: dir ? 0 : int.parse(unix.group(2)!), modified: t);
  }
  final dos = RegExp(r'^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})(AM|PM)\s+(<DIR>|\d+)\s+(.+)$', caseSensitive: false).firstMatch(line);
  if (dos != null) {
    var y = int.parse(dos.group(3)!);
    if (y < 100) y += y < 70 ? 2000 : 1900;
    var h = int.parse(dos.group(4)!) % 12;
    if (dos.group(6)!.toUpperCase() == 'PM') h += 12;
    final t = DateTime(y, int.parse(dos.group(1)!), int.parse(dos.group(2)!), h, int.parse(dos.group(5)!));
    final dir = dos.group(7)!.toUpperCase() == '<DIR>';
    final name = dos.group(8)!;
    return Entry(path: join(prefix, name), name: name, isDir: dir, size: dir ? 0 : int.parse(dos.group(7)!), modified: t);
  }
  return null;
}

/// FTP server as a remote location. One connection for browsing and one for
/// transfers, each used one command at a time.
class FtpVfs extends Vfs {
  FtpVfs(super.conn);

  FtpClient? _browse, _xfer;
  Future<void> _browseLock = Future.value(), _xferLock = Future.value();

  /// Set when the server can't do encrypted data connections.
  bool _clearData = false;

  FtpClient _make() =>
      FtpClient(host: conn.host, port: conn.port, user: conn.user, password: conn.password, tls: conn.tls, protectData: !_clearData);

  /// Server path for a vfs path ("ftp://id/a b" → "/base/a b").
  String server(String path) {
    final base = conn.folder.isEmpty ? '/' : conn.folder;
    final rel = relOf(path);
    if (rel.isEmpty) return base;
    return base.endsWith('/') ? '$base${rel.substring(1)}' : '$base$rel';
  }

  Future<T> _run<T>(bool xfer, Future<T> Function(FtpClient c) f) {
    final prev = xfer ? _xferLock : _browseLock;
    final done = Completer<void>();
    if (xfer) {
      _xferLock = done.future;
    } else {
      _browseLock = done.future;
    }
    return prev.then((_) async {
      try {
        for (var attempt = 0;; attempt++) {
          var c = xfer ? _xfer : _browse;
          try {
            if (c == null || !c.connected) {
              c = _make();
              if (xfer) {
                _xfer = c;
              } else {
                _browse = c;
              }
              await c.connect();
            }
            return await f(c);
          } on JobCancelled {
            // The connection is mid-transfer: start fresh next time.
            c?.destroy();
            if (xfer) _xfer = null;
            rethrow;
          } on TlsDataException {
            c?.destroy();
            if (xfer) {
              _xfer = null;
            } else {
              _browse = null;
            }
            if (_clearData) throw RemoteException(tr('Conexiunea de date TLS nu merge', 'The TLS data connection fails'));
            _clearData = true; // and try again with PROT C
          } on RemoteException {
            rethrow;
          } catch (e) {
            // Dropped idle connection: reconnect once.
            c?.destroy();
            if (xfer) {
              _xfer = null;
            } else {
              _browse = null;
            }
            if (attempt >= 1) rethrow;
          }
        }
      } finally {
        done.complete();
      }
    });
  }

  @override
  Future<List<Entry>> list(String path) => _run(false, (c) => c.list(server(path), path));

  @override
  Future<String> mkdir(String dir, String name) async {
    final p = join(dir, name);
    await _run(false, (c) => c.mkd(server(p)));
    return p;
  }

  @override
  Future<void> delete(Entry e) => _run(false, (c) => _rm(c, e));

  Future<void> _rm(FtpClient c, Entry e) async {
    if (!e.isDir) {
      await c.dele(server(e.path));
      return;
    }
    for (final k in await c.list(server(e.path), e.path)) {
      await _rm(c, k);
    }
    await c.cwd(server(parentOf(e.path)));
    await c.rmd(server(e.path));
  }

  @override
  Future<void> rename(Entry e, String newName) =>
      _run(false, (c) => c.rename(server(e.path), server(join(parentOf(e.path), newName))));

  @override
  Future<void> download(Entry e, String localPath, OnBytes onBytes, bool Function() cancelled) =>
      _run(true, (c) => c.retr(server(e.path), localPath, onBytes, cancelled));

  @override
  Future<void> upload(String localPath, String dir, String name, OnBytes onBytes, bool Function() cancelled) =>
      _run(true, (c) => c.stor(server(join(dir, name)), localPath, onBytes, cancelled));

  @override
  void close() {
    _browse?.quit();
    _xfer?.quit();
    _browse = _xfer = null;
  }
}

/// Tries the settings once; returns an error text or null when it works.
Future<String?> testFtp(Conn c, {bool protectData = true}) async {
  final f = FtpClient(host: c.host, port: c.port, user: c.user, password: c.password, tls: c.tls, protectData: protectData);
  try {
    await f.connect();
    final dir = c.folder.isEmpty ? '/' : c.folder;
    // Also list, so "Connected" means browsing works (data connection included).
    await f.list(dir, 'ftp://test');
    await f.quit();
    return null;
  } on TlsDataException {
    f.destroy();
    if (protectData) return testFtp(c, protectData: false);
    return tr('Conexiunea de date TLS nu merge', 'The TLS data connection fails');
  } catch (e) {
    f.destroy();
    return remoteError(e);
  }
}
