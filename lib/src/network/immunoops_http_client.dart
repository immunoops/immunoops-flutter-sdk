import 'dart:async';

import 'package:http/http.dart' as http;

import 'http_error_classifier.dart';
import 'network_recorder.dart';
import 'network_registry.dart';

/// Drop-in `http.Client` that measures every request, for code that uses
/// the `http` package instead of Dio.
///
/// ```dart
/// final client = ImmunoOpsHttpClient();          // wraps http.Client()
/// final client = ImmunoOpsHttpClient(myClient);  // or your own client
/// ```
class ImmunoOpsHttpClient extends http.BaseClient {
  ImmunoOpsHttpClient([http.Client? inner])
      : _inner = inner ?? http.Client(),
        _recorder = (() => activeNetworkRecorder);

  /// For tests: a fixed recorder instead of the SDK's.
  ImmunoOpsHttpClient.withRecorder(NetworkRecorder recorder,
      [http.Client? inner])
      : _inner = inner ?? http.Client(),
        _recorder = (() => recorder);

  final http.Client _inner;
  final NetworkRecorder? Function() _recorder;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final recorder = _recorder();
    if (recorder == null || recorder.shouldSkip(request.url)) {
      return _inner.send(request);
    }
    TraceHeaders? trace;
    try {
      trace = recorder.traceFor(request.url);
      if (trace != null) request.headers.addAll(trace.headers);
    } catch (_) {
      trace = null;
    }
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _inner.send(request);
      _safely(() => recorder.record(
            method: request.method,
            uri: request.url,
            duration: stopwatch.elapsed,
            statusCode: response.statusCode,
            trace: trace,
          ));
      return response;
    } catch (error) {
      _safely(() => recorder.record(
            method: request.method,
            uri: request.url,
            duration: stopwatch.elapsed,
            failure: error is TimeoutException
                ? HttpFailure.timeout
                : _connection(HttpErrorClassifier.classify(error)),
            trace: trace,
            exceptionType: error.runtimeType.toString(),
          ));
      rethrow;
    }
  }

  static HttpFailure _connection(HttpFailure failure) =>
      failure == HttpFailure.unknown ? HttpFailure.connection : failure;

  static void _safely(void Function() action) {
    try {
      action();
    } catch (_) {}
  }

  @override
  void close() => _inner.close();
}
