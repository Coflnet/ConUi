import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class AuthService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _userIdKey = 'user_id';
  static const String _encryptionSaltKey = 'encryption_salt';
  static const String _continuedWithoutAccountKey = 'continued_without_account';

  /// Injectable so tests can pass an `http.testing.MockClient` instead of
  /// hitting a real backend. Defaults to a plain client, so production
  /// behaviour is unchanged.
  final http.Client _http;

  AuthService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  String? _token;
  String? _userId;
  String? _encryptionSalt;
  bool _initialized = false;
  bool _continuedWithoutAccount = false;

  String? get token => _token;
  String? get userId => _userId;
  String? get encryptionSalt => _encryptionSalt;
  bool get isAuthenticated => _token != null;
  bool get isInitialized => _initialized;

  /// The user chose "Continue without account" on the login screen. The
  /// app is fully usable for recording and local data this way - see
  /// SyncService.needsSignIn and RecorderController/TranscriptionClient's
  /// notSignedIn reason for how sync and live transcription report that
  /// they need a real sign-in instead of working silently or crashing.
  bool get continuedWithoutAccount => _continuedWithoutAccount;

  /// Remembers the choice to use the app without signing in, so it isn't
  /// asked again on the next launch. Signing in for real later
  /// ([_saveToken]) or [logout] both clear it.
  Future<void> continueWithoutAccount() async {
    _continuedWithoutAccount = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_continuedWithoutAccountKey, true);
    notifyListeners();
  }

  // API base URL - configurable for different environments.
  //
  // Resolution order:
  // 1. --dart-define=API_BASE_URL=... always wins, for any platform/build.
  // 2. On web, the origin the app itself was loaded from - a web build is
  //    normally served from the same host as its backend.
  // 3. In debug builds on Android, the emulator's host-loopback address.
  // 4. Otherwise (e.g. a release build with no API_BASE_URL configured):
  //    empty. Callers must treat an empty baseUrl as "no backend
  //    configured" and report sync/transcription as unavailable rather
  //    than attempting a request against a relative/invalid URL.
  String get baseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb) return Uri.base.origin;
    if (kDebugMode) return 'http://10.0.2.2:5000';
    return '';
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _userId = prefs.getString(_userIdKey);
    _encryptionSalt = prefs.getString(_encryptionSaltKey);
    _continuedWithoutAccount = prefs.getBool(_continuedWithoutAccountKey) ?? false;
    _initialized = true;
    notifyListeners();
  }

  Future<bool> loginWithFirebase(String firebaseToken) async {
    try {
      final response = await _http.post(
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
      final response = await _http.post(
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
      final response = await _http.get(
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
    _continuedWithoutAccount = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.remove(_continuedWithoutAccountKey);

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
    _continuedWithoutAccount = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_encryptionSaltKey);
    await prefs.remove(_continuedWithoutAccountKey);

    notifyListeners();
  }

  // HTTP helper with auth header
  Future<http.Response> authenticatedGet(String path) async {
    return _http.get(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
  }

  Future<http.Response> authenticatedPost(
      String path, Map<String, dynamic> body) async {
    return _http.post(
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
    return _http.post(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );
  }

  Future<http.Response> authenticatedDelete(String path) async {
    return _http.delete(
      Uri.parse('$baseUrl$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
  }
}
