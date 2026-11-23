import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/core/rename_mask.dart';

void main() {
  final d = DateTime(2026, 7, 5, 9, 3, 7);
  String r(RenameRule rule, String f, {int i = 0, bool dir = false}) =>
      applyRule(rule, file: f, isDir: dir, parent: 'Camera', modified: d, index: i);

  test('default masks keep the name', () {
    expect(r(const RenameRule(), 'IMG_001.jpg'), 'IMG_001.jpg');
    expect(r(const RenameRule(), 'folder.v2', dir: true), 'folder.v2');
  });

  test('counter, ranges, date, parent', () {
    const rule = RenameRule(name: 'Vacanta_[C]', digits: 3, start: 1, step: 1);
    expect(r(rule, 'a.jpg', i: 0), 'Vacanta_001.jpg');
    expect(r(rule, 'b.jpg', i: 9), 'Vacanta_010.jpg');
    expect(r(const RenameRule(name: '[N1-3]'), 'IMG_001.jpg'), 'IMG.jpg');
    expect(r(const RenameRule(name: '[N5-]'), 'IMG_001.jpg'), '001.jpg');
    expect(r(const RenameRule(name: '[Y]-[M]-[D] [h][m][s]'), 'x.jpg'), '2026-07-05 090307.jpg');
    expect(r(const RenameRule(name: '[P]_[N]'), 'x.jpg'), 'Camera_x.jpg');
    expect(r(const RenameRule(ext: ''), 'x.jpg'), 'x');
  });

  test('search/replace and case', () {
    expect(r(const RenameRule(search: '_', replace: ' '), 'my_file_1.txt'), 'my file 1.txt');
    expect(r(const RenameRule(search: r'(\d+)', replace: r'#$1', regex: true), 'a12.txt'), 'a#12.txt');
    expect(r(const RenameRule(caseMode: CaseMode.upper), 'Ab.txt'), 'AB.TXT');
    expect(r(const RenameRule(caseMode: CaseMode.title), 'hello wORLD.txt'), 'Hello World.txt');
    expect(() => r(const RenameRule(search: '(', regex: true), 'a.txt'), throwsFormatException);
  });
}
