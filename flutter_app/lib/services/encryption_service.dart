import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

class EncryptionService {
  static EncryptionService? _instance;
  static EncryptionService? get instance => _instance;

  late encrypt.Key _key;
  late encrypt.IV _iv;
  late encrypt.Encrypter _encrypter;
  bool _initialized = false;

  // Derive key from password and salt using PBKDF2-like approach
  void initializeWithPassword(String password, String salt) {
    // Simple key derivation (in production, use proper PBKDF2)
    final keyData = utf8.encode('$password:$salt');
    final hash = sha256.convert(keyData);
    _key = encrypt.Key.fromBase64(base64.encode(hash.bytes));

    // Derive IV from salt
    final ivData = utf8.encode('iv:$salt');
    final ivHash = md5.convert(ivData);
    _iv = encrypt.IV.fromBase64(base64.encode(ivHash.bytes));

    _encrypter = encrypt.Encrypter(encrypt.AES(_key));
    _initialized = true;
    _instance = this;
  }

  bool get isInitialized => _initialized;

  // Encrypt data to base64 string
  String encryptString(String plainText) {
    if (!_initialized) throw StateError('Encryption not initialized');
    final encrypted = _encrypter.encrypt(plainText, iv: _iv);
    return encrypted.base64;
  }

  // Decrypt base64 string to data
  String decryptString(String encryptedBase64) {
    if (!_initialized) throw StateError('Encryption not initialized');
    final encrypted = encrypt.Encrypted.fromBase64(encryptedBase64);
    return _encrypter.decrypt(encrypted, iv: _iv);
  }

  // Encrypt bytes
  List<int> encryptBytes(List<int> data) {
    if (!_initialized) throw StateError('Encryption not initialized');
    final plainText = base64.encode(data);
    final encrypted = _encrypter.encrypt(plainText, iv: _iv);
    return encrypted.bytes;
  }

  // Decrypt bytes
  Uint8List decryptBytes(List<int> encryptedData) {
    if (!_initialized) throw StateError('Encryption not initialized');
    final encrypted = encrypt.Encrypted(Uint8List.fromList(encryptedData));
    final plainText = _encrypter.decrypt(encrypted, iv: _iv);
    return base64.decode(plainText);
  }

  // Encrypt JSON object
  String encryptJson(Map<String, dynamic> data) {
    final jsonString = jsonEncode(data);
    return encryptString(jsonString);
  }

  // Decrypt JSON object
  Map<String, dynamic> decryptJson(String encryptedBase64) {
    final jsonString = decryptString(encryptedBase64);
    return jsonDecode(jsonString);
  }

  // Calculate checksum for data integrity
  String calculateChecksum(String data) {
    final bytes = utf8.encode(data);
    return sha256.convert(bytes).toString();
  }
}
