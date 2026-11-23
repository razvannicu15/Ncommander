import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/services/secrets.dart';

void main() {
  test('sealed secrets round-trip, with and without a master password', () async {
    final plain = await sealSecret('parolă-ftp');
    expect(plain, startsWith('v1:'));
    expect(plain.contains('parolă'), isFalse);
    expect((await openSecret(plain)).plain, 'parolă-ftp');

    final salt = randomBytes(16);
    final key = await deriveKey('master123', salt);
    final locked = await sealSecret('token-onedrive', master: key);
    final o = await openSecret(locked);
    expect(o.plain, isNull);
    expect(o.locked, isNotNull);
    expect(await openLocked(key, o.locked!), 'token-onedrive');

    final wrong = await deriveKey('altceva', salt);
    expect(await openLocked(wrong, o.locked!), isNull);
    final check = await makeCheck(key);
    expect(await verifyCheck(key, check), isTrue);
    expect(await verifyCheck(wrong, check), isFalse);

    // Older files: clear text is read as-is (and re-sealed on save).
    expect((await openSecret('vechi')).plain, 'vechi');
  });
}
