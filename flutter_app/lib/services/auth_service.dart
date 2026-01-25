import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class AuthService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _userIdKey = 'user_id';
  static const String _encryptionSaltKey = 'encryption_salt';

  String? _token;
  String? _userId;
  String? _encryptionSalt;
  bool _initialized = false;

  String? get token => _token;
  String? get userId => _userId;
  String? get encryptionSalt => _encryptionSalt;
  bool get isAuthenticated => _token != null;
  bool get isInitialized => _initialized;

  // API base URL - configurable for different environments
  String get baseUrl {
    if (kIsWeb) {
      return 'http://localhost:5000';
    }
    return 'http://10.0.2.2:5000'; // Android emulator localhost
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _userId = prefs.getString(_userIdKey);
    _encryptionSalt = prefs.getString(_encryptionSaltKey);
    _initialized = true;
    notifyListeners();
  }

  Future<bool> loginWithFirebase(String firebaseToken) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/firebase'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'firebaseToken': firebaseToken}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _saveToken(data['authToken']);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Firebase login error: $e');
      return false;
    }
  }

  // Development login for testing
  Future<bool> devLogin(String userId, {String? name, String? email}) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/dev'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'name': name,
          'email': email,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _saveToken(data['authToken']);

        // Fetch user info to get encryption salt
        await _fetchUserInfo();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Dev login error: $e');
      return false;
    }
  }

  Future<void> _fetchUserInfo() async {
    if (_token == null) return;

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/auth/me'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _userId = data['id'];
        _encryptionSalt = data['encryptionKeySalt'];

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_userIdKey, _userId!);
        if (_encryptionSalt != null) {
          await prefs.setString(_encryptionSaltKey, _encryptionSalt!);
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Fetch user info error: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);

    // Decode token to get user ID
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final payload = utf8.decode(base64.decode(base64.normalize(parts[1])));
        final data = jsonDecode(payload);
        _userId = data['sub'];
        await prefs.setString(_userIdKey, _userId!);
      }
    } catch (e) {
      debugPrint('Token decode error: $e');
    }

    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _userId = null;
    _encryptionSalt = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_encryptionSaltKey);

    notifyListeners();
  }

  // HTTP helper with auth header
  Future<http.Response> authenticatedGet(String path) async {
    return http.get(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
  }

  Future<http.Response> authenticatedPost(
      String path, Map<String, dynamic> body) async {
    return http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode(body),
    );
  }

  // HTTP helper for posting raw bytes (for proxy uploads)
  Future<http.Response> authenticatedPostBytes(
      String path, List<int> body) async {
    return http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );
  }

  Future<http.Response> authenticatedDelete(String path) async {
    return http.delete(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
  }
}
