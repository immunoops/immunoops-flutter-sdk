import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/telemetry_sink.dart';

/// `app.startup.duration_ms` with `startup.type`:
/// - `cold`: from `ImmunoOps.init` to the first frame on screen. The time
///   before Dart runs (process and engine start) needs native code (v2).
/// - `warm`: from coming back to the foreground to the next frame drawn.
class StartupMonitor {
  StartupMonitor(this._sink);

  final TelemetrySink _sink;
  final _cold = Stopwatch();
  bool _coldDone = false;

  /// Called from `init`, as early as the app allows.
  void start() {
    _cold.start();
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      if (_coldDone) return;
      _coldDone = true;
      _record(_cold.elapsedMicroseconds, 'cold');
    });
  }

  /// For tests, where the first frame is never rasterized.
  @visibleForTesting
  void markColdDone() => _coldDone = true;

  /// Called when the app returns to the foreground.
  void resumed() {
    if (!_coldDone) return;
    final warm = Stopwatch()..start();
    SchedulerBinding.instance.endOfFrame.then((_) {
      _record(warm.elapsedMicroseconds, 'warm');
    });
  }

  void _record(int micros, String type) {
    _sink
      ..markActive('startup')
      ..recordMetric(
        'app.startup.duration_ms',
        micros / 1000,
        tags: {'startup.type': type},
      );
  }
}
