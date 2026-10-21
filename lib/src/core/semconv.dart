/// Attribute names. Where OpenTelemetry has a convention, its name is used
/// (see docs/architecture/ADR-002-opentelemetry.md); the rest are Immuno
/// Ops names, marked as such in docs/instrumentation.md.
abstract final class Attr {
  // Resource (OpenTelemetry).
  static const serviceName = 'service.name';
  static const serviceVersion = 'service.version';
  static const environment = 'deployment.environment.name';
  static const osName = 'os.name';
  static const osVersion = 'os.version';
  static const deviceModel = 'device.model.identifier';
  static const deviceManufacturer = 'device.manufacturer';
  static const installId = 'app.installation.id';
  static const sessionId = 'session.id';
  static const sdkName = 'telemetry.sdk.name';
  static const sdkVersion = 'telemetry.sdk.version';
  static const sdkLanguage = 'telemetry.sdk.language';

  // Resource (Immuno Ops).
  static const appBuild = 'app.build';
  static const platform = 'platform';
  static const devicePhysical = 'device.physical';

  // HTTP client (OpenTelemetry).
  static const httpMethod = 'http.request.method';
  static const httpStatus = 'http.response.status_code';
  static const serverAddress = 'server.address';
  static const urlTemplate = 'url.template';
  static const errorType = 'error.type';

  // Exceptions (OpenTelemetry).
  static const exceptionType = 'exception.type';
  static const exceptionMessage = 'exception.message';
  static const exceptionStacktrace = 'exception.stacktrace';

  // Immuno Ops.
  static const eventType = 'event.type';
  static const exceptionUnhandled = 'exception.unhandled';
  static const exceptionFingerprint = 'exception.fingerprint';
  static const exceptionSource = 'exception.source';
  static const flutterLibrary = 'flutter.library';
  static const flutterContext = 'flutter.context';
  static const screenName = 'screen.name';
  static const journeyName = 'journey.name';
  static const journeyOutcome = 'journey.outcome';
  static const durationMs = 'duration_ms';
  static const traceId = 'trace_id';
  static const spanId = 'span_id';
}

/// `event.type` values, the classification the alert rules key on.
abstract final class EventType {
  static const crash = 'mobile.crash';
  static const error = 'mobile.error';
  static const networkError = 'mobile.network.error';
  static const memoryPressure = 'mobile.memory.pressure';
  static const journeyFailure = 'mobile.journey.failure';
}
