/// Why a request failed, as the OpenTelemetry `error.type` value.
enum HttpFailure {
  timeout('timeout'),
  dns('dns_error'),
  tls('tls_error'),
  connection('connection_error'),
  cancelled('cancelled'),
  unknown('error');

  const HttpFailure(this.tag);

  final String tag;
}

/// Tells DNS, TLS and plain connection failures apart. Works from type
/// names and messages, not from dart:io types, so it also compiles for the
/// web (where the browser hides these details and everything is
/// `connection_error`).
abstract final class HttpErrorClassifier {
  static final _dns = RegExp(
    r'failed host lookup|no address associated|nodename nor servname|'
    r'name or service not known|unknownhost|name resolution',
    caseSensitive: false,
  );
  static final _tls = RegExp(
    r'handshake|certificate|ssl|tls',
    caseSensitive: false,
  );
  static final _timeout = RegExp(r'timed? ?out|timeout', caseSensitive: false);

  /// [error] is the underlying exception (Dio's `error`, or what the http
  /// client threw).
  static HttpFailure classify(Object? error) {
    if (error == null) return HttpFailure.unknown;
    final type = error.runtimeType.toString();
    String text;
    try {
      text = '$type $error';
    } catch (_) {
      text = type;
    }
    if (_tls.hasMatch(type) || _tls.hasMatch(text)) return HttpFailure.tls;
    if (_dns.hasMatch(text)) return HttpFailure.dns;
    if (type.contains('Timeout') || _timeout.hasMatch(text)) {
      return HttpFailure.timeout;
    }
    if (type.contains('Socket') ||
        type.contains('ClientException') ||
        type.contains('Connection')) {
      return HttpFailure.connection;
    }
    return HttpFailure.unknown;
  }
}
