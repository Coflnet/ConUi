import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:pointycastle/export.dart' as pc;

class EncryptionService {
  static EncryptionService? _instance;
  static EncryptionService? get instance => _instance;

  // v1 fixes the KDF, nonce and tag sizes; changes require a new version.
  static const _prefix = 'con:v1:';
  static final _header = Uint8List.fromList(utf8.encode(_prefix));
  static const _nonceLength = 12;
  static const _tagLength = 16;
  late Uint8List _key;
  late encrypt.IV _legacyIv;
  late encrypt.Encrypter _legacyEncrypter;
  bool _initialized = false;

  void initializeWithPassword(String password, String salt) {
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
      ..init(pc.Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode('con:encryption:v1:$salt')),
          600000,
          32));
    _key = derivator.process(Uint8List.fromList(utf8.encode(password)));

    // Read compatibility only: old ciphertext has no authentication. Existing
    // data is upgraded when it is next encrypted; never write this format.
    final legacyKey = encrypt.Key(Uint8List.fromList(
        sha256.convert(utf8.encode('$password:$salt')).bytes));
    _legacyIv = encrypt
        .IV(Uint8List.fromList(md5.convert(utf8.encode('iv:$salt')).bytes));
    _legacyEncrypter = encrypt.Encrypter(encrypt.AES(legacyKey));
    _initialized = true;
    _instance = this;
  }

  bool get isInitialized => _initialized;

  String encryptString(String plainText) =>
      _prefix + base64.encode(_encrypt(utf8.encode(plainText)));

  String decryptString(String encryptedText) {
    _requireInitialized();
    if (encryptedText.startsWith(_prefix)) {
      return utf8.decode(
          _decrypt(base64.decode(encryptedText.substring(_prefix.length))));
    }
    if (encryptedText.startsWith('con:')) {
      throw const FormatException('Unsupported encryption version');
    }
    return _legacyEncrypter.decrypt(encrypt.Encrypted.fromBase64(encryptedText),
        iv: _legacyIv);
  }

  List<int> encryptBytes(List<int> data) => [..._header, ..._encrypt(data)];

  Uint8List decryptBytes(List<int> encryptedData) {
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

  Uint8List _encrypt(List<int> data) {
    _requireInitialized();
    final random = Random.secure();
    final nonce = Uint8List.fromList(
        List.generate(_nonceLength, (_) => random.nextInt(256)));
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
          true, pc.AEADParameters(pc.KeyParameter(_key), 128, nonce, _header));
    return Uint8List.fromList(
        [...nonce, ...cipher.process(Uint8List.fromList(data))]);
  }

  Uint8List _decrypt(Uint8List payload) {
    if (payload.length < _nonceLength + _tagLength) {
      throw const FormatException('Truncated encrypted data');
    }
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
          false,
          pc.AEADParameters(pc.KeyParameter(_key), 128,
              payload.sublist(0, _nonceLength), _header));
    // GCM verifies the tag before returning plaintext. Authentication failure
    // must never fall back to the unauthenticated legacy decoder.
    return cipher.process(payload.sublist(_nonceLength));
  }

  void _requireInitialized() {
    if (!_initialized) throw StateError('Encryption not initialized');
  }

  String encryptJson(Map<String, dynamic> data) =>
      encryptString(jsonEncode(data));

  Map<String, dynamic> decryptJson(String encryptedText) =>
      jsonDecode(decryptString(encryptedText));

  String calculateChecksum(String data) =>
      sha256.convert(utf8.encode(data)).toString();
}
