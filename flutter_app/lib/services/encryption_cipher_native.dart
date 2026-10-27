import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;

Future<Uint8List> process(bool forEncryption, Uint8List key, Uint8List nonce,
        Uint8List header, Uint8List data) =>
    compute(_process, (forEncryption, key, nonce, header, data));

Uint8List _process((bool, Uint8List, Uint8List, Uint8List, Uint8List) input) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(input.$1,
        pc.AEADParameters(pc.KeyParameter(input.$2), 128, input.$3, input.$4));
  return cipher.process(input.$5);
}
