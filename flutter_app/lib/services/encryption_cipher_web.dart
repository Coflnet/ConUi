import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List> process(bool forEncryption, Uint8List key, Uint8List nonce,
    Uint8List header, Uint8List data) async {
  final subtle = web.window.crypto.subtle;
  final cryptoKey = await subtle
      .importKey('raw', key.toJS, 'AES-GCM'.toJS, false,
          [forEncryption ? 'encrypt'.toJS : 'decrypt'.toJS].toJS)
      .toDart;
  final algorithm = {
    'name': 'AES-GCM',
    'iv': nonce.toJS,
    'additionalData': header.toJS,
    'tagLength': 128,
  }.jsify()!;
  final result = await (forEncryption
          ? subtle.encrypt(algorithm, cryptoKey, data.toJS)
          : subtle.decrypt(algorithm, cryptoKey, data.toJS))
      .toDart;
  return (result as JSArrayBuffer).toDart.asUint8List();
}
