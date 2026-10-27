import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;

Future<Uint8List> deriveKey(String password, String salt) =>
    compute(_deriveKey, (password, salt));

Uint8List _deriveKey((String, String) credentials) {
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(pc.Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode('con:encryption:v1:${credentials.$2}')),
        600000,
        32));
  return derivator.process(Uint8List.fromList(utf8.encode(credentials.$1)));
}
