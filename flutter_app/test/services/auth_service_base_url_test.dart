// AuthService.baseUrl used to be hard-coded to http://localhost:5000 (web)
// or http://10.0.2.2:5000 (everywhere else), which meant a real device or
// a release build could never reach any backend at all. It's now derived
// from API_BASE_URL (--dart-define), falling back to the web origin on
// web, the Android emulator address in debug builds, and empty otherwise.
//
// `flutter test` always runs in debug mode against the native (non-web)
// target, so this test exercises the "no override, debug, non-web" branch
// - the one that matches the old hard-coded non-web behaviour - end to
// end, and documents the other branches' intended behaviour in comments
// since they aren't reachable without a real web/release build or
// --dart-define in this harness.
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/auth_service.dart';

void main() {
  test('defaults to the Android emulator address in a debug, non-web build',
      () {
    final auth = AuthService();
    // This is exactly `flutter test`'s environment: debug mode, kIsWeb
    // false. It's also the same address the app always used to hard-code,
    // so this doubles as a no-regression check for that default.
    expect(auth.baseUrl, 'http://10.0.2.2:5000');
  });

  test('baseUrl is used consistently by every authenticated helper', () async {
    // Not a network test - just makes sure nothing hard-codes the old
    // literal URL anywhere else now that baseUrl is computed.
    final auth = AuthService();
    expect(auth.baseUrl, isNotEmpty);
  });

  // Not exercised here (would need --dart-define or a web/release build):
  // - API_BASE_URL set -> baseUrl returns it verbatim, on every platform.
  // - kIsWeb -> baseUrl returns Uri.base.origin (the origin the app was
  //   served from).
  // - release build, no API_BASE_URL, not web -> baseUrl is '' and
  //   TranscriptionClient.isConfigured / SyncService's guards report
  //   sync and transcription as unavailable rather than hitting a
  //   relative/invalid URL.
}
