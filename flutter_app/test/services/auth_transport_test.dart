import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:relationship_manager/services/oidc/auth_transport.dart';

class _DelayedClient extends http.BaseClient {
  final requests = <http.AbortableRequest>[];
  final body = Completer<http.StreamedResponse>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request as http.AbortableRequest);
    return body.future;
  }
}

void main() {
  test('one overall eight-second budget aborts code exchange without replay',
      () async {
    final client = _DelayedClient();
    final timer = Stopwatch()..start();
    final pending = authCompletion(() => authRequest(
        Uri.parse('https://identity.example/token'),
        body: {'code': 'one-use', 'code_verifier': 'verifier'},
        client: client));
    await Future<void>.delayed(Duration.zero);
    var aborted = false;
    client.requests.single.abortTrigger!.then((_) => aborted = true);
    await expectLater(pending, throwsA(isA<OidcUnavailable>()));
    expect(timer.elapsed, lessThan(const Duration(seconds: 10)));
    expect(timer.elapsed, greaterThanOrEqualTo(const Duration(seconds: 7)));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
    expect(client.requests, hasLength(1));
    expect(client.requests.single.followRedirects, isFalse);
    client.body.complete(http.StreamedResponse(Stream.value([123, 125]), 200));
    await Future<void>.delayed(Duration.zero);
    expect(client.requests, hasLength(1),
        reason: 'late completion never retransmits authorization code');
  });

  test(
      'deadline includes previous machine work rather than restarting per request',
      () async {
    await authCompletion(() async {
      final before = authRemaining();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(authRemaining(), lessThan(before));
    });
  });
}
