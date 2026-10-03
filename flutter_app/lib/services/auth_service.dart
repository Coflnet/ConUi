import 'dart:convert';
import 'oidc/oidc_flow.dart';
import 'oidc/oidc_platform.dart' as oidc;
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

  final Future<String?> Function(OidcConfig, String, http.Client) _beginSignIn;
  final Future<String?> Function(http.Client) _finishSignIn;
  AuthService(
      {http.Client? httpClient,
      Future<String?> Function(OidcConfig, String, http.Client)? beginSignIn,
      Future<String?> Function(http.Client)? finishSignIn})
      : _http = httpClient ?? http.Client(),
        _beginSignIn = beginSignIn ?? oidc.beginOidcLogin,
        _finishSignIn = finishSignIn ?? oidc.completeOidcLogin;

  bool signInFailed = false;
  bool signInUnavailable = false;

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
    signInFailed = false;
    signInUnavailable = false;
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
  // 4. Release native builds use the production Con backend.
  String get baseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    if (kIsWeb) return Uri.base.origin;
    if (kDebugMode) return 'http://10.0.2.2:5000';
    return 'https://con.coflnet.com';
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _userId = prefs.getString(_userIdKey);
    _encryptionSalt = prefs.getString(_encryptionSaltKey);
    _continuedWithoutAccount =
        prefs.getBool(_continuedWithoutAccountKey) ?? false;
    try {
      final accessToken = await _finishSignIn(_http);
      if (accessToken != null) await _acceptOidcToken(accessToken);
    } catch (_) {
      signInFailed = true;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<bool> signIn({String locale = 'de'}) async {
    signInFailed = false;
    signInUnavailable = false;
    OidcConfig config;
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl/api/auth/config'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw const FormatException('Unavailable');
      }
      config = OidcConfig.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    } catch (_) {
      signInUnavailable = true;
      notifyListeners();
      return false;
    }
    try {
      final accessToken = await _beginSignIn(config, locale, _http);
      if (accessToken == null) return false; // Browser is redirecting.
      await _acceptOidcToken(accessToken);
      return true;
    } catch (_) {
      signInFailed = true;
      notifyListeners();
      return false;
    }
  }

  Future<void> _acceptOidcToken(String accessToken) async {
    final response = await _http
        .post(Uri.parse('$baseUrl/api/auth/oidc'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'accessToken': accessToken}))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw const FormatException('Sign-in rejected');
    }
    final token = (jsonDecode(response.body)
        as Map<String, dynamic>)['authToken'] as String;
    final me = await _http.get(Uri.parse('$baseUrl/api/auth/me'), headers: {
      'Authorization': 'Bearer $token'
    }).timeout(const Duration(seconds: 15));
    if (me.statusCode != 200) {
      throw const FormatException('Account verification failed');
    }
    final user = jsonDecode(me.body) as Map<String, dynamic>;
    final id = user['id'] as String;
    final salt = user['encryptionKeySalt'] as String;
    final payload = jsonDecode(utf8
        .decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))));
    if (id.isEmpty || salt.isEmpty || payload['sub'] != id) {
      throw const FormatException('Account mismatch');
    }
    await _saveToken(token, encryptionSalt: salt);
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

  Future<void> _saveToken(String token, {String? encryptionSalt}) async {
    String? userId;
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final payload =
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
        userId =
            (jsonDecode(payload) as Map<String, dynamic>)['sub'] as String?;
      }
    } catch (e) {
      debugPrint('Token decode error: $e');
    }
    final salt = encryptionSalt ?? (userId == _userId ? _encryptionSalt : null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.remove(_continuedWithoutAccountKey);
    if (userId == null) {
      await prefs.remove(_userIdKey);
    } else {
      await prefs.setString(_userIdKey, userId);
    }
    if (salt == null) {
      await prefs.remove(_encryptionSaltKey);
    } else {
      await prefs.setString(_encryptionSaltKey, salt);
    }
    // Publish one coherent identity after all asynchronous work is complete.
    _token = token;
    _userId = userId;
    _encryptionSalt = salt;
    _continuedWithoutAccount = false;
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
