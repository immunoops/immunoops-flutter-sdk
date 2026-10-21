import '../core/semconv.dart';
import '../core/telemetry_item.dart';
import '../core/telemetry_sink.dart';

/// How a journey ended.
enum JourneyOutcome { success, failure, abandoned }

/// One run of a business journey (`checkout.payment`). End it exactly once
/// with [end], [fail] or [abandon]; later calls are ignored.
class ImmunoOpsJourney {
  ImmunoOpsJourney._(this._tracker, this.name, this.attributes, this.startedAt);

  /// A journey that records nothing, for calls made before `init`.
  ImmunoOpsJourney.noop(this.name)
      : _tracker = null,
        attributes = const {},
        startedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final JourneyTracker? _tracker;
  final String name;
  final Map<String, String> attributes;
  final DateTime startedAt;
  bool _finished = false;

  bool get finished => _finished;

  /// The journey reached its goal (payment confirmed, class booked).
  void end({Map<String, String>? attributes}) =>
      _finish(JourneyOutcome.success, attributes: attributes);

  /// The journey failed; [error] is recorded as an error log tied to it.
  void fail(
          [Object? error,
          StackTrace? stackTrace,
          Map<String, String>? attributes]) =>
      _finish(JourneyOutcome.failure,
          error: error, stackTrace: stackTrace, attributes: attributes);

  /// The user gave up (left the screen, closed the app).
  void abandon() => _finish(JourneyOutcome.abandoned);

  void _finish(
    JourneyOutcome outcome, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  }) {
    if (_finished) return;
    _finished = true;
    _tracker?._finish(this, outcome, error, stackTrace, attributes ?? const {});
  }
}

/// Measures journeys: `journey.duration_ms` per name and outcome, the
/// `journey_start` / `journey_end` events, and an error log
/// (`event.type: mobile.journey.failure`) when one fails. The most recent
/// open journey is the [current] one, attached to errors and requests.
class JourneyTracker {
  JourneyTracker(
    this._sink, {
    this.timeout = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final TelemetrySink _sink;
  final Duration timeout;
  final DateTime Function() _now;
  final _open = <ImmunoOpsJourney>[];

  String? get current => _open.isEmpty ? null : _open.last.name;

  ImmunoOpsJourney start(String name, {Map<String, String>? attributes}) {
    _sink.markActive('journeys');
    final journey =
        ImmunoOpsJourney._(this, name, attributes ?? const {}, _now());
    _open.add(journey);
    _sink.recordEvent('journey_start', {
      Attr.journeyName: name,
      ...journey.attributes,
    });
    return journey;
  }

  void _finish(
    ImmunoOpsJourney journey,
    JourneyOutcome outcome,
    Object? error,
    StackTrace? stackTrace,
    Map<String, String> extra,
  ) {
    _open.remove(journey);
    final duration = _now().difference(journey.startedAt).inMilliseconds;
    final tags = {
      Attr.journeyName: journey.name,
      Attr.journeyOutcome: outcome.name,
      ...journey.attributes,
      ...extra,
    };
    _sink.recordMetric('journey.duration_ms', duration.toDouble(), tags: tags);
    _sink.recordEvent('journey_end', {
      ...tags,
      Attr.durationMs: duration,
      if (error != null) Attr.exceptionType: error.runtimeType.toString(),
    });
    if (outcome == JourneyOutcome.failure) {
      _sink.recordLog(
        ImmunoOpsLogLevel.error,
        'Jornada ${journey.name} falhou'
        '${error == null ? '' : ': ${error.runtimeType}'}',
        context: {
          ...tags,
          Attr.eventType: EventType.journeyFailure,
          Attr.durationMs: duration,
          if (error != null) Attr.exceptionType: error.runtimeType.toString(),
          if (error != null) Attr.exceptionMessage: _safeString(error),
          if (stackTrace != null)
            Attr.exceptionStacktrace: _limit(_safeString(stackTrace), 8000),
          if (_sink.currentScreen != null) Attr.screenName: _sink.currentScreen,
        },
      );
    }
  }

  /// Open journeys older than [timeout] count as abandoned.
  void expire() {
    final now = _now();
    for (final journey in List.of(_open)) {
      if (now.difference(journey.startedAt) >= timeout) journey.abandon();
    }
  }

  /// A new session closes whatever the previous one left open.
  void abandonAll() {
    for (final journey in List.of(_open)) {
      journey.abandon();
    }
  }

  static String _safeString(Object value) {
    try {
      return value.toString();
    } catch (_) {
      return value.runtimeType.toString();
    }
  }

  static String _limit(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}…' : text;
}
