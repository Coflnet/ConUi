import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

import 'encryption_kdf_native.dart'
    if (dart.library.js_interop) 'encryption_kdf_web.dart' as kdf;
import 'encryption_cipher_native.dart'
    if (dart.library.js_interop) 'encryption_cipher_web.dart' as cipher;

class EncryptionService {
  static EncryptionService? instance;

  // v1 fixes the KDF, nonce and tag sizes; changes require a new version.
  static const _prefix = 'con:v1:';
  static final _header = Uint8List.fromList(utf8.encode(_prefix));
  static const _nonceLength = 12;
  static const _tagLength = 16;
  late Uint8List _key;
  late encrypt.IV _legacyIv;
  late encrypt.Encrypter _legacyEncrypter;
  bool _initialized = false;

  Future<void> initializeWithPassword(String password, String salt) async {
    final key = await kdf.deriveKey(password, salt);

    // Read compatibility only: old ciphertext has no authentication. Existing
    // data is upgraded when it is next encrypted; never write this format.
    final legacyKey = encrypt.Key(Uint8List.fromList(
        sha256.convert(utf8.encode('$password:$salt')).bytes));
    _legacyIv = encrypt
        .IV(Uint8List.fromList(md5.convert(utf8.encode('iv:$salt')).bytes));
    _legacyEncrypter = encrypt.Encrypter(encrypt.AES(legacyKey));
    _key = key;
    _initialized = true;
  }

  bool get isInitialized => _initialized;

  Future<String> encryptString(String plainText) async =>
      _prefix + base64.encode(await _encrypt(utf8.encode(plainText)));

  Future<String> decryptString(String encryptedText) async {
    _requireInitialized();
    if (encryptedText.startsWith(_prefix)) {
      return utf8.decode(await _decrypt(
          base64.decode(encryptedText.substring(_prefix.length))));
    }
    if (encryptedText.startsWith('con:')) {
      throw const FormatException('Unsupported encryption version');
    }
    return _legacyEncrypter.decrypt(encrypt.Encrypted.fromBase64(encryptedText),
        iv: _legacyIv);
  }

  Future<List<int>> encryptBytes(List<int> data) async {
    final payload = await _encrypt(data);
    return Uint8List(_header.length + payload.length)
      ..setAll(0, _header)
      ..setAll(_header.length, payload);
  }

  Future<Uint8List> decryptBytes(List<int> encryptedData) async {
    _requireInitialized();
    final bytes = Uint8List.fromList(encryptedData);
    if (bytes.length >= 4 &&
        utf8.decode(bytes.sublist(0, 4), allowMalformed: true) == 'con:') {
      if (bytes.length < _header.length ||
          utf8.decode(bytes.sublist(0, _header.length), allowMalformed: true) !=
              _prefix) {
        throw const FormatException('Unsupported encryption version');
      }
      return _decrypt(bytes.sublist(_header.length));
    }
    final plainText =
        _legacyEncrypter.decrypt(encrypt.Encrypted(bytes), iv: _legacyIv);
    return base64.decode(plainText);
  }

  Future<Uint8List> _encrypt(List<int> data) async {
    _requireInitialized();
    final random = Random.secure();
    final nonce = Uint8List.fromList(
        List.generate(_nonceLength, (_) => random.nextInt(256)));
    final encrypted = await cipher.process(
        true, _key, nonce, _header, Uint8List.fromList(data));
    return Uint8List(nonce.length + encrypted.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, encrypted);
  }

  Future<Uint8List> _decrypt(Uint8List payload) {
    if (payload.length < _nonceLength + _tagLength) {
      throw const FormatException('Truncated encrypted data');
    }
    // Both implementations verify the tag before returning plaintext. Never
    // fall back to the unauthenticated legacy decoder after a v1 failure.
    return cipher.process(false, _key, payload.sublist(0, _nonceLength),
        _header, payload.sublist(_nonceLength));
  }

  void _requireInitialized() {
    if (!_initialized) throw StateError('Encryption not initialized');
  }

  Future<String> encryptJson(Map<String, dynamic> data) =>
      encryptString(jsonEncode(data));

  Future<Map<String, dynamic>> decryptJson(String encryptedText) async =>
      jsonDecode(await decryptString(encryptedText));

  String calculateChecksum(String data) =>
      sha256.convert(utf8.encode(data)).toString();
}
