import 'dart:math';

import '../core/semconv.dart';
import '../core/telemetry_item.dart';
import '../core/telemetry_sink.dart';
import '../rum/route_template.dart';
import 'http_error_classifier.dart';

/// The trace context the SDK puts on an outgoing request.
class TraceHeaders {
  const TraceHeaders(
      this.traceId, this.spanId, this.traceparent, this.tracestate);

  final String traceId;
  final String spanId;
  final String traceparent;
  final String? tracestate;

  Map<String, String> get headers => {
        'traceparent': traceparent,
        if (tracestate != null) 'tracestate': tracestate!,
      };
}

/// Shared by the Dio interceptor and the http client wrapper: one metric
/// per request (`http.client.request.duration_ms`), an error log for 5xx,
/// 429 and transport failures (`event.type: mobile.network.error`), and
/// the trace headers for hosts the app opted in. Never reads bodies,
/// headers or query strings.
class NetworkRecorder {
  NetworkRecorder(
    this._sink, {
    required Uri ingestUri,
    required List<String> traceHosts,
    Random? random,
  })  : _ingestUri = ingestUri,
        _traceHosts = {for (final h in traceHosts) h.toLowerCase()},
        _random = random ?? Random.secure();

  final TelemetrySink _sink;
  final Uri _ingestUri;
  final Set<String> _traceHosts;
  final Random _random;

  /// The SDK's own uploads are not measured: that would feed itself.
  bool shouldSkip(Uri uri) =>
      uri.host == _ingestUri.host && uri.path == _ingestUri.path;

  /// W3C trace context for hosts the app opted in, else null. The
  /// `tracestate` entry carries the session id, so the backend's trace can
  /// be tied back to the app session.
  TraceHeaders? traceFor(Uri uri) {
    if (!_traceHosts.contains(uri.host.toLowerCase())) return null;
    final traceId = _hex(16);
    final spanId = _hex(8);
    final session = _sink.sessionId;
    return TraceHeaders(
      traceId,
      spanId,
      '00-$traceId-$spanId-01',
      session == null ? null : 'immunoops=s:$session',
    );
  }

  String _hex(int bytes) => List.generate(
        bytes,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  /// [statusCode] when the server answered; [failure] when it did not.
  void record({
    required String method,
    required Uri uri,
    required Duration duration,
    int? statusCode,
    HttpFailure? failure,
    TraceHeaders? trace,
    String? exceptionType,
  }) {
    _sink.markActive('network');
    final route = normalizePath(uri.path);
    final journey = _sink.currentJourney;
    final errorType = failure?.tag ??
        (statusCode != null && statusCode >= 400 ? '$statusCode' : null);
    final tags = {
      Attr.httpMethod: method.toUpperCase(),
      Attr.serverAddress: uri.host,
      Attr.urlTemplate: route,
      if (statusCode != null) Attr.httpStatus: '$statusCode',
      if (errorType != null) Attr.errorType: errorType,
      if (journey != null) Attr.journeyName: journey,
    };
    _sink.recordMetric(
      'http.client.request.duration_ms',
      duration.inMicroseconds / 1000,
      tags: tags,
      network: true,
    );
    final cancelled = failure == HttpFailure.cancelled;
    final serverError = statusCode != null && statusCode >= 500;
    final throttled = statusCode == 429;
    if (cancelled || !(serverError || throttled || failure != null)) return;
    _sink.recordLog(
      serverError || failure != null
          ? ImmunoOpsLogLevel.error
          : ImmunoOpsLogLevel.warn,
      'HTTP ${statusCode ?? failure!.tag} ${method.toUpperCase()} '
      '${uri.host}$route',
      context: {
        ...tags,
        Attr.eventType: EventType.networkError,
        Attr.durationMs: duration.inMilliseconds,
        if (exceptionType != null) Attr.exceptionType: exceptionType,
        if (trace != null) Attr.traceId: trace.traceId,
        if (trace != null) Attr.spanId: trace.spanId,
        if (_sink.currentScreen != null) Attr.screenName: _sink.currentScreen,
      },
    );
  }
}
