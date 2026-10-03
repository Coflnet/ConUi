import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/encryption_service.dart';

void main() {
  late EncryptionService service;
  late EncryptionService otherDevice;
  late EncryptionService wrongPassword;
  late EncryptionService wrongSalt;

  setUpAll(() {
    service = EncryptionService()..initializeWithPassword('password', 'salt');
    otherDevice = EncryptionService()
      ..initializeWithPassword('password', 'salt');
    wrongPassword = EncryptionService()
      ..initializeWithPassword('wrong', 'salt');
    wrongSalt = EncryptionService()
      ..initializeWithPassword('password', 'other');
  });

  test('all encryption operations require initialization', () {
    final locked = EncryptionService();
    expect(() => locked.encryptString('text'), throwsStateError);
    expect(() => locked.decryptString('text'), throwsStateError);
    expect(() => locked.encryptBytes([1]), throwsStateError);
    expect(() => locked.decryptBytes([1]), throwsStateError);
  });

  test('versioned strings, JSON and binary round trip across devices', () {
    for (final text in ['', 'Grüße aus Berlin', '😀']) {
      final encrypted = service.encryptString(text);
      expect(encrypted, startsWith('con:v1:'));
      expect(otherDevice.decryptString(encrypted), text);
    }
    final json = {'name': 'Anna', 'story': 'Bruder von Hans', 'year': 1980};
    expect(otherDevice.decryptJson(service.encryptJson(json)), json);
    for (final bytes in [<int>[], List.generate(256, (i) => i)]) {
      expect(otherDevice.decryptBytes(service.encryptBytes(bytes)), bytes);
    }
  });

  test('decrypts an independent Node/OpenSSL AES-GCM known-answer vector', () {
    // PBKDF2-SHA256(password, con:encryption:v1:salt, 600000, 32),
    // nonce 000102030405060708090a0b, AAD con:v1:, tag 128 bits.
    const envelope = 'con:v1:'
        'AAECAwQFBgcICQoLYaMZbQHlsln6Yfr6itrFtd2VPhT9hWf7WNElO5BygkZ02A==';
    expect(service.decryptString(envelope), 'Grüße aus Berlin');
    final bytes = [
      ...utf8.encode('con:v1:'),
      ...base64.decode(envelope.substring(7))
    ];
    expect(utf8.decode(service.decryptBytes(bytes)), 'Grüße aus Berlin');
  });

  test('same plaintext receives a fresh nonce each time', () {
    expect(
        service.encryptString('story'), isNot(service.encryptString('story')));
    expect(service.encryptBytes([1, 2, 3]),
        isNot(service.encryptBytes([1, 2, 3])));
  });

  test('wrong password or account salt never returns plaintext', () {
    final text = service.encryptString('private story');
    final bytes = service.encryptBytes([0, 255]);
    for (final wrong in [wrongPassword, wrongSalt]) {
      expect(() => wrong.decryptString(text), throwsA(anything));
      expect(() => wrong.decryptBytes(bytes), throwsA(anything));
    }
  });

  test('nonce, ciphertext and authentication tag tampering fails closed', () {
    final envelope = service.encryptBytes(List.generate(32, (i) => i));
    for (final offset in [7, 19, envelope.length - 1]) {
      final changed = List<int>.from(envelope)..[offset] ^= 1;
      expect(() => service.decryptBytes(changed), throwsA(anything));
      final text = 'con:v1:${base64.encode(changed.sublist(7))}';
      expect(() => service.decryptString(text), throwsA(anything));
    }
  });

  test('unknown versions and truncated envelopes are rejected', () {
    expect(() => service.decryptString('con:v2:AAAA'), throwsFormatException);
    expect(() => service.decryptBytes(utf8.encode('con:v2:AAAA')),
        throwsFormatException);
    expect(() => service.decryptString('con:v1:AAAA'), throwsFormatException);
    expect(() => service.decryptBytes(utf8.encode('con:v1:')),
        throwsFormatException);
    final bytes = service.encryptBytes([1, 2, 3]);
    expect(() => service.decryptBytes(bytes.sublist(0, bytes.length - 1)),
        throwsA(anything));
  });

  test('legacy persisted strings and base64-wrapped bytes remain readable', () {
    // Exact former derivation and AES/SIC/PKCS7 encoding; only reads retain it.
    final key = encrypt.Key(
        Uint8List.fromList(sha256.convert(utf8.encode('password:salt')).bytes));
    final iv = encrypt
        .IV(Uint8List.fromList(md5.convert(utf8.encode('iv:salt')).bytes));
    final legacy = encrypt.Encrypter(encrypt.AES(key));
    final text = legacy.encrypt('Grüße aus Berlin', iv: iv).base64;
    expect(service.decryptString(text), 'Grüße aus Berlin');
    final bytes = [0, 1, 127, 128, 255];
    final encryptedBytes = legacy.encrypt(base64.encode(bytes), iv: iv).bytes;
    expect(service.decryptBytes(encryptedBytes), bytes);
    expect(service.encryptString(service.decryptString(text)),
        startsWith('con:v1:'));
  });
}
