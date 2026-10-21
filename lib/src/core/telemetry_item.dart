/// Severity of a log line, matching the backend's `level` values.
enum ImmunoOpsLogLevel { debug, info, warn, error }

/// Metric kinds the backend stores.
enum MetricType { gauge, counter, histogram }

/// One unit of telemetry waiting to be sent. Its JSON is exactly what
/// `POST /agent/ingest/v1/custom` reads (`IngestTelemetryPayload` in
/// internal/gateway/usecase/custom_telemetry_usecase.go).
sealed class TelemetryItem {
  const TelemetryItem(this.timestampMs);

  final int timestampMs;

  Map<String, Object?> toJson();

  static TelemetryItem? fromJson(Map<String, Object?> json) {
    switch (json['kind']) {
      case 'metric':
        return MetricItem.fromJson(json);
      case 'log':
        return LogItem.fromJson(json);
      case 'event':
        return EventItem.fromJson(json);
    }
    return null;
  }

  /// The item plus its kind, for the on-disk queue.
  Map<String, Object?> toStoredJson();
}

class MetricItem extends TelemetryItem {
  const MetricItem({
    required this.name,
    required this.value,
    required int timestampMs,
    this.type = MetricType.gauge,
    this.tags = const {},
  }) : super(timestampMs);

  factory MetricItem.fromJson(Map<String, Object?> json) => MetricItem(
        name: json['name'] as String? ?? '',
        value: (json['value'] as num?)?.toDouble() ?? 0,
        type: MetricType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => MetricType.gauge,
        ),
        tags: _stringMap(json['tags']),
        timestampMs: json['timestamp_ms'] as int? ?? 0,
      );

  final String name;
  final double value;
  final MetricType type;
  final Map<String, String> tags;

  @override
  Map<String, Object?> toJson() => {
        'name': name,
        'value': value,
        'type': type.name,
        'tags': tags,
        'timestamp_ms': timestampMs,
      };

  @override
  Map<String, Object?> toStoredJson() => {'kind': 'metric', ...toJson()};
}

class LogItem extends TelemetryItem {
  const LogItem({
    required this.level,
    required this.message,
    required int timestampMs,
    this.context = const {},
  }) : super(timestampMs);

  factory LogItem.fromJson(Map<String, Object?> json) => LogItem(
        level: ImmunoOpsLogLevel.values.firstWhere(
          (l) => l.name == json['level'],
          orElse: () => ImmunoOpsLogLevel.info,
        ),
        message: json['message'] as String? ?? '',
        context: _objectMap(json['context']),
        timestampMs: json['timestamp_ms'] as int? ?? 0,
      );

  final ImmunoOpsLogLevel level;
  final String message;
  final Map<String, Object?> context;

  @override
  Map<String, Object?> toJson() => {
        'level': level.name,
        'message': message,
        'context': context,
        'timestamp_ms': timestampMs,
      };

  @override
  Map<String, Object?> toStoredJson() => {'kind': 'log', ...toJson()};
}

class EventItem extends TelemetryItem {
  const EventItem({
    required this.name,
    required int timestampMs,
    this.payload = const {},
  }) : super(timestampMs);

  factory EventItem.fromJson(Map<String, Object?> json) => EventItem(
        name: json['event_name'] as String? ?? '',
        payload: _objectMap(json['payload']),
        timestampMs: json['timestamp_ms'] as int? ?? 0,
      );

  final String name;
  final Map<String, Object?> payload;

  @override
  Map<String, Object?> toJson() => {
        'event_name': name,
        'payload': payload,
        'timestamp_ms': timestampMs,
      };

  @override
  Map<String, Object?> toStoredJson() => {'kind': 'event', ...toJson()};
}

/// Turns anything an app may pass in a context or payload into a value
/// `jsonEncode` accepts: a DateTime, an enum, NaN or an object of the app
/// would otherwise make the whole batch impossible to send.
Object? jsonSafe(Object? value, [int depth = 0]) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) return value.isFinite ? value : null;
  if (value is num) return value.toDouble();
  if (depth > 8) return '…';
  if (value is Map) {
    return {
      for (final e in value.entries) '${e.key}': jsonSafe(e.value, depth + 1),
    };
  }
  if (value is Iterable) {
    return [for (final v in value.take(200)) jsonSafe(v, depth + 1)];
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Enum) return value.name;
  try {
    return value.toString();
  } catch (_) {
    return value.runtimeType.toString();
  }
}

Map<String, Object?> jsonSafeMap(Map<String, Object?> map) =>
    jsonSafe(map)! as Map<String, Object?>;

/// The request body for one batch.
Map<String, Object?> buildIngestPayload(
  String appName,
  Iterable<TelemetryItem> items,
) {
  final metrics = <Map<String, Object?>>[];
  final logs = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  for (final item in items) {
    switch (item) {
      case MetricItem():
        metrics.add(item.toJson());
      case LogItem():
        logs.add(item.toJson());
      case EventItem():
        events.add(item.toJson());
    }
  }
  return {
    'app_name': appName,
    if (metrics.isNotEmpty) 'metrics': metrics,
    if (logs.isNotEmpty) 'logs': logs,
    if (events.isNotEmpty) 'events': events,
  };
}

Map<String, String> _stringMap(Object? value) => value is Map
    ? {for (final e in value.entries) '${e.key}': '${e.value}'}
    : const {};

Map<String, Object?> _objectMap(Object? value) => value is Map
    ? {for (final e in value.entries) '${e.key}': e.value}
    : const {};
