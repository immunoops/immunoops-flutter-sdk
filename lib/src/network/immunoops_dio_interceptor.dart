import 'package:dio/dio.dart';

import 'http_error_classifier.dart';
import 'network_recorder.dart';
import 'network_registry.dart';

const _startKey = 'immunoops.start';
const _traceKey = 'immunoops.trace';

/// Measures every request of the Dio it is added to. Safe to create before
/// `ImmunoOps.init`: until then it does nothing.
///
/// ```dart
/// dio.interceptors.add(ImmunoOpsDioInterceptor());
/// ```
class ImmunoOpsDioInterceptor extends Interceptor {
  ImmunoOpsDioInterceptor() : _recorder = (() => activeNetworkRecorder);

  /// For tests: a fixed recorder instead of the SDK's.
  ImmunoOpsDioInterceptor.withRecorder(NetworkRecorder recorder)
      : _recorder = (() => recorder);

  final NetworkRecorder? Function() _recorder;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      final recorder = _recorder();
      if (recorder != null && !recorder.shouldSkip(options.uri)) {
        options.extra[_startKey] = Stopwatch()..start();
        final trace = recorder.traceFor(options.uri);
        if (trace != null) {
          options.headers.addAll(trace.headers);
          options.extra[_traceKey] = trace;
        }
      }
    } catch (_) {
      // Measuring must never stop a request.
    }
    handler.next(options);
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    _finish(response.requestOptions, statusCode: response.statusCode);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final code = err.response?.statusCode;
    _finish(
      err.requestOptions,
      statusCode: code,
      failure: code != null
          ? null
          : switch (err.type) {
              DioExceptionType.connectionTimeout ||
              DioExceptionType.sendTimeout ||
              DioExceptionType.receiveTimeout =>
                HttpFailure.timeout,
              DioExceptionType.cancel => HttpFailure.cancelled,
              DioExceptionType.badCertificate => HttpFailure.tls,
              _ => _refine(HttpErrorClassifier.classify(err.error)),
            },
      exceptionType: err.error?.runtimeType.toString(),
    );
    handler.next(err);
  }

  /// A connection error with no recognisable cause stays a connection
  /// error rather than an unknown one.
  static HttpFailure _refine(HttpFailure failure) =>
      failure == HttpFailure.unknown ? HttpFailure.connection : failure;

  void _finish(
    RequestOptions options, {
    int? statusCode,
    HttpFailure? failure,
    String? exceptionType,
  }) {
    try {
      final stopwatch = options.extra.remove(_startKey);
      if (stopwatch is! Stopwatch) return;
      _recorder()?.record(
        method: options.method,
        uri: options.uri,
        duration: stopwatch.elapsed,
        statusCode: statusCode,
        failure: failure,
        trace: options.extra.remove(_traceKey) as TraceHeaders?,
        exceptionType: exceptionType,
      );
    } catch (_) {
      // Measuring must never change the response the app sees.
    }
  }
}
