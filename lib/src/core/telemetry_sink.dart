import 'telemetry_item.dart';

/// What the captures write to. The client implements it; tests use a fake.
abstract interface class TelemetrySink {
  void recordMetric(
    String name,
    double value, {
    MetricType type = MetricType.gauge,
    Map<String, String> tags = const {},
    bool network = false,
  });

  void recordLog(
    ImmunoOpsLogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  });

  void recordEvent(String name, [Map<String, Object?> payload = const {}]);

  /// The screen the user is on, for tagging errors and frames.
  String? get currentScreen;
  set currentScreen(String? screen);

  /// The most recent business journey still open (`checkout.payment`),
  /// attached to errors and requests that happen inside it.
  String? get currentJourney;

  /// The session id, carried to the app's backend in `tracestate`.
  String? get sessionId;

  /// Marks a capture as live, for the self-check and the handshake.
  void markActive(String capture);
}
