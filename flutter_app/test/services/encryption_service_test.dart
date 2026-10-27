import 'dart:async';
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

  setUpAll(() async {
    service = EncryptionService();
    await service.initializeWithPassword('password', 'salt');
    otherDevice = EncryptionService();
    await otherDevice.initializeWithPassword('password', 'salt');
    wrongPassword = EncryptionService();
    await wrongPassword.initializeWithPassword('wrong', 'salt');
    wrongSalt = EncryptionService();
    await wrongSalt.initializeWithPassword('password', 'other');
  });

  test('key derivation lets the event loop run before unlocking', () async {
    final locked = EncryptionService();
    var eventProcessed = false;
    final event = Timer(Duration.zero, () => eventProcessed = true);
    try {
      final initialization = locked.initializeWithPassword('password', 'salt');
      expect(locked.isInitialized, isFalse);
      await expectLater(locked.encryptString('text'), throwsStateError);
      await initialization;
      expect(eventProcessed, isTrue);
      expect(locked.isInitialized, isTrue);
    } finally {
      event.cancel();
    }
  });

  test('all encryption operations require initialization', () async {
    final locked = EncryptionService();
    await expectLater(locked.encryptString('text'), throwsStateError);
    await expectLater(locked.decryptString('text'), throwsStateError);
    await expectLater(locked.encryptBytes([1]), throwsStateError);
    await expectLater(locked.decryptBytes([1]), throwsStateError);
  });

  test('versioned strings, JSON and binary round trip across devices',
      () async {
    for (final text in ['', 'Grüße aus Berlin', '😀']) {
      final encrypted = await service.encryptString(text);
      expect(encrypted, startsWith('con:v1:'));
      expect(await otherDevice.decryptString(encrypted), text);
    }
    final json = {'name': 'Anna', 'story': 'Bruder von Hans', 'year': 1980};
    expect(
        await otherDevice.decryptJson(await service.encryptJson(json)), json);
    for (final bytes in [<int>[], List.generate(256, (i) => i)]) {
      expect(await otherDevice.decryptBytes(await service.encryptBytes(bytes)),
          bytes);
    }
  });

  test('decrypts an independent Node/OpenSSL AES-GCM known-answer vector',
      () async {
    // PBKDF2-SHA256(password, con:encryption:v1:salt, 600000, 32),
    // nonce 000102030405060708090a0b, AAD con:v1:, tag 128 bits.
    const envelope = 'con:v1:'
        'AAECAwQFBgcICQoLYaMZbQHlsln6Yfr6itrFtd2VPhT9hWf7WNElO5BygkZ02A==';
    expect(await service.decryptString(envelope), 'Grüße aus Berlin');
    final bytes = [
      ...utf8.encode('con:v1:'),
      ...base64.decode(envelope.substring(7))
    ];
    expect(utf8.decode(await service.decryptBytes(bytes)), 'Grüße aus Berlin');
  });

  test('same plaintext receives a fresh nonce each time', () async {
    expect(await service.encryptString('story'),
        isNot(await service.encryptString('story')));
    expect(await service.encryptBytes([1, 2, 3]),
        isNot(await service.encryptBytes([1, 2, 3])));
  });

  test('wrong password or account salt never returns plaintext', () async {
    final text = await service.encryptString('private story');
    final bytes = await service.encryptBytes([0, 255]);
    for (final wrong in [wrongPassword, wrongSalt]) {
      await expectLater(wrong.decryptString(text), throwsA(anything));
      await expectLater(wrong.decryptBytes(bytes), throwsA(anything));
    }
  });

  test('nonce, ciphertext and authentication tag tampering fails closed',
      () async {
    final envelope = await service.encryptBytes(List.generate(32, (i) => i));
    for (final offset in [7, 19, envelope.length - 1]) {
      final changed = List<int>.from(envelope)..[offset] ^= 1;
      await expectLater(service.decryptBytes(changed), throwsA(anything));
      final text = 'con:v1:${base64.encode(changed.sublist(7))}';
      await expectLater(service.decryptString(text), throwsA(anything));
    }
  });

  test('unknown versions and truncated envelopes are rejected', () async {
    await expectLater(
        service.decryptString('con:v2:AAAA'), throwsFormatException);
    await expectLater(service.decryptBytes(utf8.encode('con:v2:AAAA')),
        throwsFormatException);
    await expectLater(
        service.decryptString('con:v1:AAAA'), throwsFormatException);
    await expectLater(
        service.decryptBytes(utf8.encode('con:v1:')), throwsFormatException);
    final bytes = await service.encryptBytes([1, 2, 3]);
    await expectLater(service.decryptBytes(bytes.sublist(0, bytes.length - 1)),
        throwsA(anything));
  });

  test('multi-MiB v1 operations keep the event loop responsive throughout',
      () async {
    final bytes = Uint8List(2 * 1024 * 1024);
    final text = 'x' * bytes.length;
    late List<int> encryptedBytes;
    late String encryptedText;
    for (final operation in <Future<Object> Function()>[
      () async => encryptedBytes = await service.encryptBytes(bytes),
      () => otherDevice.decryptBytes(encryptedBytes),
      () async => encryptedText = await service.encryptString(text),
      () => otherDevice.decryptString(encryptedText),
    ]) {
      final clock = Stopwatch()..start();
      var lastTick = 0;
      var maxGap = 0;
      void sample() {
        final now = clock.elapsedMilliseconds;
        final gap = now - lastTick;
        if (gap > maxGap) maxGap = gap;
        lastTick = now;
      }

      final timer =
          Timer.periodic(const Duration(milliseconds: 10), (_) => sample());
      try {
        await operation();
        sample();
        // DDC browser tests include debug codec/copy overhead; the optimized
        // browser harness enforces a tighter 250 ms budget for 4 MiB.
        expect(maxGap, lessThan(1000),
            reason: 'No part of a v1 operation should block the event loop');
      } finally {
        timer.cancel();
      }
    }
  });

  test('legacy persisted strings and base64-wrapped bytes remain readable',
      () async {
    // Exact former derivation and AES/SIC/PKCS7 encoding; only reads retain it.
    final key = encrypt.Key(
        Uint8List.fromList(sha256.convert(utf8.encode('password:salt')).bytes));
    final iv = encrypt
        .IV(Uint8List.fromList(md5.convert(utf8.encode('iv:salt')).bytes));
    final legacy = encrypt.Encrypter(encrypt.AES(key));
    final text = legacy.encrypt('Grüße aus Berlin', iv: iv).base64;
    expect(await service.decryptString(text), 'Grüße aus Berlin');
    final bytes = [0, 1, 127, 128, 255];
    final encryptedBytes = legacy.encrypt(base64.encode(bytes), iv: iv).bytes;
    expect(await service.decryptBytes(encryptedBytes), bytes);
    expect(await service.encryptString(await service.decryptString(text)),
        startsWith('con:v1:'));
  });
}
