import 'package:immunoops_flutter/src/core/telemetry_item.dart';
import 'package:immunoops_flutter/src/core/telemetry_sink.dart';

class RecordedMetric {
  RecordedMetric(this.name, this.value, this.type, this.tags, this.network);
  final String name;
  final double value;
  final MetricType type;
  final Map<String, String> tags;
  final bool network;
}

class FakeSink implements TelemetrySink {
  final metrics = <RecordedMetric>[];
  final logs = <LogItem>[];
  final events = <EventItem>[];
  final active = <String>{};

  @override
  String? currentScreen;

  @override
  String? currentJourney;

  @override
  String? sessionId = 'sess-1';

  @override
  void markActive(String capture) => active.add(capture);

  @override
  void recordMetric(
    String name,
    double value, {
    MetricType type = MetricType.gauge,
    Map<String, String> tags = const {},
    bool network = false,
  }) =>
      metrics.add(RecordedMetric(name, value, type, tags, network));

  @override
  void recordLog(
    ImmunoOpsLogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) =>
      logs.add(LogItem(
          level: level, message: message, context: context, timestampMs: 0));

  @override
  void recordEvent(String name, [Map<String, Object?> payload = const {}]) =>
      events.add(EventItem(name: name, payload: payload, timestampMs: 0));

  List<RecordedMetric> named(String name) =>
      metrics.where((m) => m.name == name).toList();
}
