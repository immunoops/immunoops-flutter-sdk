import '../context/app_context.dart';
import '../semconv.dart';
import '../telemetry_sink.dart';

/// Sessions: one starts at launch and again after [timeout] in the
/// background. Emits `session_start`, `app_background` (with
/// `foreground_ms`) and `app_foreground` (with `background_ms`).
class SessionManager {
  SessionManager(
    this._sink, {
    required this.timeout,
    this.emitEvents = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final TelemetrySink _sink;
  final Duration timeout;

  /// False when the app turned the sessions capture off: ids still rotate
  /// (logs need one), but no session events are sent.
  final bool emitEvents;
  final DateTime Function() _now;

  String _id = randomId();
  DateTime? _foregroundSince;
  DateTime? _backgroundSince;

  String get id => _id;
  bool get inBackground => _backgroundSince != null;

  /// Starts a session; [previous] links it to the one it replaces.
  void start({String? previous}) {
    _id = randomId();
    _foregroundSince = _now();
    if (!emitEvents) return;
    _sink
      ..markActive('sessions')
      ..recordEvent('session_start', {
        Attr.sessionId: _id,
        if (previous != null) 'session.previous_id': previous,
      });
  }

  /// Returns false when the app was already in the background.
  bool background() {
    if (_backgroundSince != null) return false;
    _backgroundSince = _now();
    final since = _foregroundSince;
    if (!emitEvents) return true;
    _sink.recordEvent('app_background', {
      if (since != null)
        'foreground_ms': _now().difference(since).inMilliseconds,
    });
    return true;
  }

  /// Returns true when the absence was long enough to start a new session.
  bool foreground() {
    final since = _backgroundSince;
    _backgroundSince = null;
    if (since == null) return false;
    final away = _now().difference(since);
    if (away >= timeout) {
      start(previous: _id);
      return true;
    }
    _foregroundSince = _now();
    if (emitEvents) {
      _sink.recordEvent(
          'app_foreground', {'background_ms': away.inMilliseconds});
    }
    return false;
  }
}
