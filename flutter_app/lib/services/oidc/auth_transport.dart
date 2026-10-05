import 'dart:async';
import 'package:http/http.dart' as http;

class OidcUnavailable implements Exception {}

// Start at the first machine request, after any human authorization wait.
class _Deadline {
  final elapsed = Stopwatch();
  Duration get remaining {
    if (!elapsed.isRunning) elapsed.start();
    final value = const Duration(seconds: 8) - elapsed.elapsed;
    if (value <= Duration.zero) throw OidcUnavailable();
    return value;
  }
}

const _deadlineKey = #oidcDeadline;
Future<T> authCompletion<T>(Future<T> Function() operation) =>
    runZoned(operation, zoneValues: {_deadlineKey: _Deadline()});
Duration authRemaining() =>
    (Zone.current[_deadlineKey] as _Deadline? ?? _Deadline()).remaining;

Future<http.Response> authRequest(
  Uri url, {
  Map<String, String>? body,
  String? encodedBody,
  Map<String, String>? headers,
  http.Client? client,
}) async {
  final transport = client ?? http.Client();
  final abort = Completer<void>();
  final request = http.AbortableRequest(
    body == null && encodedBody == null ? 'GET' : 'POST',
    url,
    abortTrigger: abort.future,
  )..followRedirects = false;
  if (headers != null) request.headers.addAll(headers);
  if (body != null) request.bodyFields = body;
  if (encodedBody != null) request.body = encodedBody;
  try {
    final remaining = authRemaining();
    final response = await transport
        .send(request)
        .then(http.Response.fromStream)
        .timeout(remaining, onTimeout: () {
      abort.complete();
      throw OidcUnavailable();
    });
    if (response.statusCode >= 500) throw OidcUnavailable();
    return response;
  } on http.ClientException {
    throw OidcUnavailable();
  } finally {
    if (client == null) transport.close();
  }
}
