import '../core/semconv.dart';
import '../core/telemetry_item.dart';
import '../core/telemetry_sink.dart';
import 'memory_reader.dart';

/// The app's resident memory (`app.memory.rss_mb`, sampled) and the
/// system's low-memory signal, which comes before the OS kills the app
/// (`memory_pressure` event plus a warning log, `event.type:
/// mobile.memory.pressure`). An out-of-memory kill itself is not visible
/// to Dart.
class MemoryMonitor {
  MemoryMonitor(this._sink);

  final TelemetrySink _sink;
  DateTime? _lastPressure;

  void sample() {
    final rss = currentRssBytes();
    if (rss == null) return;
    _sink
      ..markActive('device')
      ..recordMetric('app.memory.rss_mb', rss / (1024 * 1024));
  }

  /// From WidgetsBindingObserver.didHaveMemoryPressure. The OS can repeat
  /// it in bursts; one report a minute is enough.
  void onPressure() {
    final now = DateTime.now();
    final last = _lastPressure;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastPressure = now;
    final rss = currentRssBytes();
    final context = {
      Attr.eventType: EventType.memoryPressure,
      if (rss != null) 'app.memory.rss_mb': (rss / (1024 * 1024)).round(),
      if (_sink.currentScreen != null) Attr.screenName: _sink.currentScreen,
      if (_sink.currentJourney != null) Attr.journeyName: _sink.currentJourney,
    };
    _sink
      ..recordEvent('memory_pressure', context)
      ..recordLog(ImmunoOpsLogLevel.warn, 'Pressão de memória do sistema',
          context: context);
  }
}
