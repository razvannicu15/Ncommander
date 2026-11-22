// Talks to real FTP servers started by CI (pyftpdlib, Pure-FTPd, Pure-FTPd + TLS).
// FTP_SERVERS="name|host|port|user|password|tls;..." — skipped when unset.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/core/i18n.dart';
import 'package:ncommander/models/entry.dart';
import 'package:ncommander/services/fs.dart';
import 'package:ncommander/services/store.dart';
import 'package:ncommander/services/vfs.dart';
import 'package:ncommander/services/vfs_ftp.dart';

void main() {
  final env = Platform.environment['FTP_SERVERS'] ?? '';
  final specs = env.split(';').where((s) => s.trim().isNotEmpty).toList();
  for (final spec in specs) {
    final f = spec.split('|');
    group(f[0], () => serverTests(Conn(
          id: 'srv_${f[0]}',
          type: ConnType.ftp,
          name: f[0],
          host: f[1],
          port: int.parse(f[2]),
          user: f[3],
          password: f[4],
          tls: f[5] == '1',
        )));
  }
  parserTests();
}

void serverTests(Conn conn) {
  const skip = false;
  late Directory tmp;
  late FtpVfs v;

  setUpAll(() {
    store.language = 'ro';
    setLanguage('ro');
    store.conns.add(conn);
    v = vfsFor(conn.root)! as FtpVfs;
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('ncftp_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FileOps ops() => FileOps((_) async => const ConflictAnswer(ConflictAction.overwrite, forAll: true));

  test('lists the root quickly', () async {
    final list = await v.list(conn.root).timeout(const Duration(seconds: 20));
    expect(list, isA<List<Entry>>());
  });

  test('login errors are readable', () async {
    final bad = Conn(id: 'x', type: ConnType.ftp, name: 'x', host: conn.host, port: conn.port, user: conn.user, password: 'wrong', tls: conn.tls);
    expect(await testFtp(bad), contains('parolă'));
    expect(await testFtp(conn), isNull);
  }, skip: skip);

  test('mkdir, upload, list, download, rename, delete', () async {
    final root = conn.root;
    final dir = await v.mkdir(root, 'Poze vară');
    final f = File('${tmp.path}/ăîș test.txt')..writeAsStringSync('salut ftp');
    await v.upload(f.path, dir, 'ăîș test.txt', (_) {}, () => false);
    final list = await v.list(dir);
    expect(list.map((e) => e.name), contains('ăîș test.txt'));
    final e = list.firstWhere((e) => e.name == 'ăîș test.txt');
    expect(e.size, 9);
    expect(e.isDir, isFalse);
    final back = '${tmp.path}/back.txt';
    var bytes = 0;
    await v.download(e, back, (d) => bytes += d, () => false);
    expect(File(back).readAsStringSync(), 'salut ftp');
    expect(bytes, 9);
    await v.rename(e, 'nou.txt');
    expect((await v.find(dir, 'nou.txt'))?.size, 9);
    final dirEntry = (await v.list(root)).firstWhere((x) => x.name == 'Poze vară');
    expect(dirEntry.isDir, isTrue);
    await v.delete(dirEntry);
    expect((await v.list(root)).any((x) => x.name == 'Poze vară'), isFalse);
  }, skip: skip);

  test('copy a local tree to FTP and back, then move', () async {
    final src = Directory('${tmp.path}/proiect/sub')..createSync(recursive: true);
    File('${tmp.path}/proiect/a.txt').writeAsStringSync('A' * 3000);
    File('${src.path}/b.bin').writeAsBytesSync(List.generate(300000, (i) => i % 251));
    final up = Job(JobKind.copy, ['${tmp.path}/proiect'], target: conn.root);
    await ops().run(up);
    expect(up.errors, isEmpty);
    expect(up.doneBytes, up.totalBytes);
    final remoteDir = (await v.list(conn.root)).firstWhere((e) => e.name == 'proiect');

    Directory('${tmp.path}/jos').createSync();
    final down = Job(JobKind.copy, [remoteDir.path], target: '${tmp.path}/jos', items: [remoteDir]);
    await ops().run(down);
    expect(down.errors, isEmpty);
    expect(File('${tmp.path}/jos/proiect/sub/b.bin').readAsBytesSync(), File('${src.path}/b.bin').readAsBytesSync());

    final mv = Job(JobKind.move, [remoteDir.path], target: '${tmp.path}/mutat', items: [remoteDir]);
    await ops().run(mv);
    expect(mv.errors, isEmpty);
    expect(File('${tmp.path}/mutat/proiect/a.txt').lengthSync(), 3000);
    expect((await v.list(conn.root)).any((e) => e.name == 'proiect'), isFalse);
  }, skip: skip);

  test('conflict skip keeps the remote file', () async {
    final f = File('${tmp.path}/c.txt')..writeAsStringSync('vechi');
    await v.upload(f.path, conn.root, 'c.txt', (_) {}, () => false);
    f.writeAsStringSync('nou nou');
    final j = Job(JobKind.copy, [f.path], target: conn.root);
    await FileOps((_) async => const ConflictAnswer(ConflictAction.skip)).run(j);
    expect((await v.find(conn.root, 'c.txt'))?.size, 5);
    final del = Job(JobKind.delete, ['${conn.root}/c.txt'], items: [(await v.find(conn.root, 'c.txt'))!]);
    await ops().run(del);
    expect(await v.find(conn.root, 'c.txt'), isNull);
  }, skip: skip);

}

void parserTests() {
  test('path helpers for remote paths', () {
    expect(parentOf('ftp://id/a/b'), 'ftp://id/a');
    expect(parentOf('ftp://id/a'), 'ftp://id');
    expect(parentOf('ftp://id'), 'ftp://id');
    expect(rootOf('gdrive://x/My/F'), 'gdrive://x');
    expect(relOf('ftp://id/a/b'), '/a/b');
    expect(nameOf('ftp://id/a/b c'), 'b c');
    expect(join('ftp://id', 'x'), 'ftp://id/x');
  });

  test('listing parsers', () {
    final u = parseList('drwxr-xr-x    2 1000     1000         4096 Nov 22 14:05 Poze vacanta', 'ftp://i');
    expect(u?.name, 'Poze vacanta');
    expect(u?.isDir, isTrue);
    final f = parseList('-rw-r--r--   1 owner group 1234567 Jan  3  2024 raport final.pdf', 'ftp://i');
    expect(f?.size, 1234567);
    expect(f?.modified.year, 2024);
    final d = parseList('11-22-26  02:05PM       <DIR>          Documents', 'ftp://i');
    expect(d?.isDir, isTrue);
    expect(d?.modified.hour, 14);
    final m = parseMlsd('type=file;size=42;modify=20261122140500; a b.txt', 'ftp://i/x');
    expect(m?.path, 'ftp://i/x/a b.txt');
    expect(m?.size, 42);
    expect(parseMlsd('type=cdir;modify=20261122140500; .', 'ftp://i'), isNull);
    final e = Entry(path: 'ftp://i/x', name: 'x', isDir: false, size: 1, modified: DateTime(2026));
    expect(e.kind.name, 'other');
  });
}
