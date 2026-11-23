import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/core/format.dart';
import 'package:ncommander/core/i18n.dart';
import 'package:ncommander/models/entry.dart';
import 'package:ncommander/services/fs.dart';

late Directory tmp;

String p(String rel) => '${tmp.path}/$rel';

void write(String rel, [String text = 'x']) {
  final f = File(p(rel));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}

FileOps ops([ConflictAction a = ConflictAction.overwrite, bool all = true]) =>
    FileOps((_) async => ConflictAnswer(a, forAll: all));

void main() {
  test('Windows drive paths', () {
    expect(parentOf('C:/Users'), 'C:/');
    expect(parentOf('C:/Users/ana/Downloads'), 'C:/Users/ana');
    expect(parentOf('C:/'), 'C:/');
    expect(parentOf('D:'), 'D:/');
    expect(join('C:/', 'Users'), 'C:/Users');
    expect(nameOf('C:/Users/ana'), 'ana');
    expect(isInside('C:/Users/ana', 'C:/'), isTrue);
    expect(isInside('D:/x', 'C:/'), isFalse);
  });

  setUp(() {
    setLanguage('ro');
    tmp = Directory.systemTemp.createTempSync('nc_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('format', () {
    test('sizes', () {
      expect(fmtSize(512), '512 B');
      expect(fmtSize(1536), '1,5 KB');
      setLanguage('en');
      expect(fmtSize(1536), '1.5 KB');
      expect(fmtSize(5 * 1024 * 1024 * 1024), '5.0 GB');
    });
    test('romanian plurals', () {
      expect(filesText(1), '1 fișier');
      expect(filesText(3), '3 fișiere');
      expect(filesText(20), '20 de fișiere');
      expect(filesText(105), '105 fișiere');
      expect(filesText(120), '120 de fișiere');
    });
    test('masks', () {
      expect(matchesMask('IMG_001.JPG', '*.jpg'), isTrue);
      expect(matchesMask('a.png', '*.jpg;*.png'), isTrue);
      expect(matchesMask('a.pdf', '*.jpg;*.png'), isFalse);
      expect(matchesMask('raport final.docx', 'final'), isTrue);
      expect(matchesMask('img_12.jpg', 'img_??.*'), isTrue);
      expect(matchesMask('img_123.jpg', 'img_??.*'), isFalse);
    });
    test('names', () {
      expect(extOf('a.tar.gz'), 'gz');
      expect(extOf('.bashrc'), '');
      expect(stemOf('photo.jpg'), 'photo');
      expect(uniqueName('a.txt', (n) => n == 'a.txt' || n == 'a (1).txt'), 'a (2).txt');
      expect(validateName('a/b'), isNotNull);
      expect(validateName('ok name.txt'), isNull);
    });
    test('paths', () {
      expect(parentOf('/storage/emulated/0/DCIM'), '/storage/emulated/0');
      expect(parentOf('/a'), '/');
      expect(nameOf('/a/b/c.txt'), 'c.txt');
      expect(isInside('/a/b/c', '/a/b'), isTrue);
      expect(isInside('/a/bc', '/a/b'), isFalse);
    });
  });

  test('natural sort, folders first', () {
    final now = DateTime(2026);
    Entry f(String n, {bool d = false, int s = 0}) => Entry(path: '/x/$n', name: n, isDir: d, size: s, modified: now);
    final list = [f('img10.jpg', s: 5), f('img2.jpg', s: 9), f('Zeta', d: true), f('alpha', d: true), f('b.txt', s: 1)];
    expect(sortEntries(list, const SortOrder(SortBy.name, true)).map((e) => e.name).toList(),
        ['alpha', 'Zeta', 'b.txt', 'img2.jpg', 'img10.jpg']);
    expect(sortEntries(list, const SortOrder(SortBy.size, false)).map((e) => e.name).toList(),
        ['alpha', 'Zeta', 'img2.jpg', 'img10.jpg', 'b.txt']);
  });

  test('list folder', () {
    write('d/a.txt', 'hello');
    Directory(p('d/sub')).createSync();
    final r = listDirSync(p('d'));
    expect(r.entries.map((e) => e.name).toSet(), {'a.txt', 'sub'});
    expect(r.entries.firstWhere((e) => e.name == 'a.txt').size, 5);
    expect(r.entries.firstWhere((e) => e.name == 'sub').isDir, isTrue);
  });

  test('copy tree with progress', () async {
    write('src/one.txt', 'abc');
    write('src/deep/two.txt', 'defgh');
    final j = Job(JobKind.copy, [p('src')], target: p('dst'));
    await ops().run(j);
    expect(File(p('dst/src/one.txt')).readAsStringSync(), 'abc');
    expect(File(p('dst/src/deep/two.txt')).readAsStringSync(), 'defgh');
    expect(j.totalBytes, 8);
    expect(j.doneBytes, 8);
    expect(j.errors, isEmpty);
    expect(Directory(p('src')).existsSync(), isTrue);
  });

  test('copy into same folder makes a copy name', () async {
    write('a/x.txt');
    await ops().run(Job(JobKind.copy, [p('a/x.txt')], target: p('a')));
    expect(File(p('a/x (1).txt')).existsSync(), isTrue);
  });

  test('copy folder into itself is refused', () async {
    write('a/x.txt');
    final j = Job(JobKind.copy, [p('a')], target: p('a/inner'));
    await ops().run(j);
    expect(j.errors, isNotEmpty);
    expect(Directory(p('a/inner')).existsSync(), isFalse);
  });

  test('conflicts: skip keeps old, overwrite replaces, rename adds number', () async {
    write('s/f.txt', 'new');
    write('t/f.txt', 'old');
    await ops(ConflictAction.skip).run(Job(JobKind.copy, [p('s/f.txt')], target: p('t')));
    expect(File(p('t/f.txt')).readAsStringSync(), 'old');
    await ops(ConflictAction.rename).run(Job(JobKind.copy, [p('s/f.txt')], target: p('t')));
    expect(File(p('t/f (1).txt')).readAsStringSync(), 'new');
    await ops(ConflictAction.overwrite).run(Job(JobKind.copy, [p('s/f.txt')], target: p('t')));
    expect(File(p('t/f.txt')).readAsStringSync(), 'new');
  });

  test('move renames on same volume and merges folders', () async {
    write('s/dir/a.txt', 'a');
    write('s/dir/b.txt', 'b');
    write('t/dir/c.txt', 'c');
    final j = Job(JobKind.move, [p('s/dir')], target: p('t'));
    await ops().run(j);
    expect(File(p('t/dir/a.txt')).existsSync(), isTrue);
    expect(File(p('t/dir/c.txt')).existsSync(), isTrue);
    expect(Directory(p('s/dir')).existsSync(), isFalse);
  });

  test('move merge keeps skipped source files', () async {
    write('s/dir/a.txt', 'new');
    write('s/dir/b.txt', 'b');
    write('t/dir/a.txt', 'old');
    await ops(ConflictAction.skip).run(Job(JobKind.move, [p('s/dir')], target: p('t')));
    expect(File(p('t/dir/a.txt')).readAsStringSync(), 'old');
    expect(File(p('t/dir/b.txt')).existsSync(), isTrue);
    expect(File(p('s/dir/a.txt')).readAsStringSync(), 'new');
  });

  test('delete', () async {
    write('d/x/y.txt');
    write('d/z.txt');
    await ops().run(Job(JobKind.delete, [p('d/x'), p('d/z.txt')]));
    expect(Directory(p('d')).listSync(), isEmpty);
  });

  test('cancel stops and cleans partial file', () async {
    write('big.bin', 'x' * (3 << 20));
    final j = Job(JobKind.copy, [p('big.bin')], target: p('out'));
    j.changes.listen((_) => j.cancelled = true);
    await ops().run(j);
    expect(j.cancelled, isTrue);
    expect(File(p('out/big.bin')).existsSync(), isFalse);
    expect(File(p('out/big.bin.ncpart')).existsSync(), isFalse);
  });

  test('zip, browse and extract', () async {
    write('z/a.txt', 'alpha');
    write('z/sub/b.txt', 'beta');
    final zj = Job(JobKind.zip, [p('z')], target: tmp.path, zipName: 'z.zip');
    await ops().run(zj);
    expect(zj.errors, isEmpty);
    final items = await readZip(p('z.zip'));
    expect(items.where((i) => !i.isDir).map((i) => i.name).toSet(), {'z/a.txt', 'z/sub/b.txt'});
    final ej = Job(JobKind.extract, [p('z.zip')], target: p('out'));
    await ops().run(ej);
    expect(ej.errors, isEmpty);
    expect(File(p('out/z/sub/b.txt')).readAsStringSync(), 'beta');
    await extractOne(p('z.zip'), 'z/a.txt', p('one/a.txt'));
    expect(File(p('one/a.txt')).readAsStringSync(), 'alpha');
  });

  test('measure', () async {
    write('m/a.txt', '12345');
    write('m/s/b.txt', '123');
    final s = await measure([p('m')]);
    expect(s.bytes, 8);
    expect(s.files, 2);
    expect(s.dirs, 2);
  });

  test('search streams matches', () async {
    write('r/a/photo1.jpg');
    write('r/b/c/photo2.JPG');
    write('r/b/doc.pdf');
    final found = <String>[];
    await for (final batch in search(p('r'), const SearchQuery(mask: '*.jpg'))) {
      found.addAll(batch.map((e) => e.name));
    }
    expect(found.toSet(), {'photo1.jpg', 'photo2.JPG'});
  });

  test('advanced search: type, size, content', () async {
    write('r/a.jpg', 'x' * 2000);
    write('r/b.jpg', 'x');
    write('r/notes/todo.txt', 'cumpără lapte și PÂINE');
    write('r/notes/other.txt', 'nimic');
    Future<Set<String>> run(SearchQuery q) async {
      final out = <String>{};
      await for (final b in search(p('r'), q)) {
        out.addAll(b.map((e) => e.name));
      }
      return out;
    }

    expect(await run(const SearchQuery(kinds: {'image'}, minSize: 1000)), {'a.jpg'});
    expect(await run(const SearchQuery(content: 'pâine')), {'todo.txt'});
    expect(await run(const SearchQuery(foldersOnly: true)), {'notes'});
    expect(await run(const SearchQuery(mask: '*.txt', recursive: false)), isEmpty);
  });
}
