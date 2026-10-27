// Compile with `dart compile js -O2 --packages=.dart_tool/package_config.json`
// and serve the output from loopback in an HTML script tag. The JSON body
// contains measurements; data-done/data-passed expose the bounded result.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import '../../lib/services/encryption_service.dart';
import '../../lib/services/wav.dart';

Future<void> main() async {
  final service = EncryptionService();
  final kdf = Stopwatch()..start();
  await service.initializeWithPassword('synthetic-password', 'synthetic-salt');
  final results = <Map<String, Object>>[
    {'operation': 'WebCrypto PBKDF2', 'ms': kdf.elapsedMilliseconds}
  ];
  Future<void> measure(
      String name, int bytes, Future<Object> Function() action) async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final started = Stopwatch()..start();
    var lastTick = 0;
    var maxGapUs = 0;
    void sample() {
      final now = started.elapsedMicroseconds;
      final gap = now - lastTick;
      if (gap > maxGapUs) maxGapUs = gap;
      lastTick = now;
    }

    final timer =
        Timer.periodic(const Duration(milliseconds: 10), (_) => sample());
    final value = await action();
    sample();
    timer.cancel();
    results.add({
      'operation': name,
      'bytes': bytes,
      'elapsedMs': started.elapsedMicroseconds / 1000,
      'maxEventLoopGapMs': maxGapUs / 1000,
      'outputLength': value is List ? value.length : (value as String).length
    });
    web.document.body!.textContent = jsonEncode(results);
  }

  for (final size in [65536, 1048576, 4194304]) {
    final bytes = Uint8List(size);
    final text = 'x' * size;
    late List<int> encrypted;
    await measure('encryptBytes', size,
        () async => encrypted = await service.encryptBytes(bytes));
    await measure('decryptBytes', size, () => service.decryptBytes(encrypted));
    late String envelope;
    await measure('encryptString', size,
        () async => envelope = await service.encryptString(text));
    await measure('decryptString', size, () => service.decryptString(envelope));
    await measure('jsonEncode', size, () async => jsonEncode({'story': text}));
    await measure(
        'calculateChecksum', size, () async => service.calculateChecksum(text));
    await measure('hashWavStream', size, () async {
      final result = await hashWavStream(
          Stream.fromIterable([WavHeader.build(dataLength: size), bytes]),
          dataLength: size);
      return result.sha256Hex;
    });
  }
  web.document.body!.dataset['passed'] = results
      .where((row) => row.containsKey('maxEventLoopGapMs'))
      .every((row) => (row['maxEventLoopGapMs'] as num) < 250)
      .toString();
  web.document.body!.dataset['done'] = 'true';
}
