import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List> deriveKey(String password, String salt) async {
  final subtle = web.window.crypto.subtle;
  final key = await subtle
      .importKey(
        'raw',
        Uint8List.fromList(utf8.encode(password)).toJS,
        'PBKDF2'.toJS,
        false,
        ['deriveBits'.toJS].toJS,
      )
      .toDart;
  final bits = await subtle
      .deriveBits(
        {
          'name': 'PBKDF2',
          'salt':
              Uint8List.fromList(utf8.encode('con:encryption:v1:$salt')).toJS,
          'iterations': 600000,
          'hash': 'SHA-256',
        }.jsify()!,
        key,
        256,
      )
      .toDart;
  return bits.toDart.asUint8List();
}
