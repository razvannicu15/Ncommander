import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/core/i18n.dart';

void main() {
  test('translation helper', () {
    setLanguage('ro');
    expect(tr('Copiază', 'Copy'), 'Copiază');
    setLanguage('en');
    expect(tr('Copiază', 'Copy'), 'Copy');
  });
}
