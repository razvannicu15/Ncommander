// Saved passwords and tokens are never written in clear text:
//  1. always: sealed by the system (Windows DPAPI / Android Keystore), so the
//     settings file is useless on another PC or phone;
//  2. optionally: encrypted first with a key from the master password
//     (PBKDF2-SHA256 + AES-256-GCM), asked once per session.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'win.dart';

const _ch = MethodChannel('ncommander/native');
final _aes = AesGcm.with256bits();
final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);
const _check = 'ncommander-master-ok';

/// System layer (identity where there is none, e.g. in tests).
Future<Uint8List?> osSeal(Uint8List b, {required bool seal}) async {
  if (Platform.isWindows) return dpapi(b, protect: seal);
  if (Platform.isAndroid) {
    try {
      return await _ch.invokeMethod<Uint8List>(seal ? 'protect' : 'unprotect', b);
    } catch (_) {
      return null;
    }
  }
  return b;
}

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<SecretKey> deriveKey(String password, Uint8List salt) => _kdf.deriveKeyFromPassword(password: password, nonce: salt);

Future<Uint8List> aesSeal(SecretKey key, Uint8List plain) async {
  final box = await _aes.encrypt(plain, secretKey: key);
  return box.concatenation();
}

/// Null when the key is wrong or the data damaged.
Future<Uint8List?> aesOpen(SecretKey key, Uint8List data) async {
  try {
    final box = SecretBox.fromConcatenation(data, nonceLength: 12, macLength: 16, copy: true);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: key));
  } catch (_) {
    return null;
  }
}

Future<String> makeCheck(SecretKey key) async => base64.encode(await aesSeal(key, Uint8List.fromList(utf8.encode(_check))));

Future<bool> verifyCheck(SecretKey key, String check) async {
  final b = await aesOpen(key, base64.decode(check));
  return b != null && utf8.decode(b) == _check;
}

/// "v1:" + base64(system-sealed( 0|utf8  or  1|aes(utf8) )).
Future<String> sealSecret(String plain, {SecretKey? master}) async {
  if (plain.isEmpty) return '';
  final raw = Uint8List.fromList(utf8.encode(plain));
  final inner = master == null ? Uint8List.fromList([0, ...raw]) : Uint8List.fromList([1, ...await aesSeal(master, raw)]);
  final sealed = await osSeal(inner, seal: true);
  if (sealed == null) throw StateError('system seal failed');
  return 'v1:${base64.encode(sealed)}';
}

/// Result of opening a sealed secret: the text, or the master-encrypted bytes
/// still waiting for the master password, or nothing if it can't be read here.
class Opened {
  const Opened({this.plain, this.locked});
  final String? plain;
  final Uint8List? locked;
}

Future<Opened> openSecret(String sealed) async {
  if (sealed.isEmpty) return const Opened(plain: '');
  if (!sealed.startsWith('v1:')) return Opened(plain: sealed); // older files: clear text
  final inner = await osSeal(base64.decode(sealed.substring(3)), seal: false);
  if (inner == null || inner.isEmpty) return const Opened();
  if (inner[0] == 0) return Opened(plain: utf8.decode(inner.sublist(1)));
  return Opened(locked: inner.sublist(1));
}

Future<String?> openLocked(SecretKey key, Uint8List locked) async {
  final b = await aesOpen(key, locked);
  return b == null ? null : utf8.decode(b);
}
