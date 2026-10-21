import 'dart:ui';

import 'package:flutter/scheduler.dart';

import '../core/telemetry_item.dart';
import '../core/semconv.dart';
import '../core/telemetry_sink.dart';

/// Frame counts for one screen since the last report.
class _FrameStats {
  int total = 0;
  int slow = 0;
  int frozen = 0;
  double worstMs = 0;
}

/// Counts slow frames (over the display's frame budget) and frozen frames
/// (over 700 ms) per screen, and reports them each flush as
/// `ui.frames.total`, `ui.frames.slow`, `ui.frames.frozen`,
/// `ui.frame.jank_ratio` and `ui.frame.worst_ms`.
class FrameMonitor {
  FrameMonitor(this._sink, {double? refreshRate})
      : _budgetMs = 1000 / (refreshRate ?? _displayRate());

  final TelemetrySink _sink;
  final double _budgetMs;
  final _stats = <String, _FrameStats>{};
  bool _installed = false;

  static const frozenMs = 700.0;

  static double _displayRate() {
    try {
      final rate = PlatformDispatcher.instance.views.first.display.refreshRate;
      return rate >= 30 && rate <= 240 ? rate : 60;
    } catch (_) {
      return 60;
    }
  }

  void install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(onTimings);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }

  void onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      record(
        buildMs: timing.buildDuration.inMicroseconds / 1000,
        rasterMs: timing.rasterDuration.inMicroseconds / 1000,
      );
    }
  }

  /// One frame; build and raster run on separate threads, so the frame is
  /// late when either one is over budget.
  void record({required double buildMs, required double rasterMs}) {
    _sink.markActive('frames');
    final worst = buildMs > rasterMs ? buildMs : rasterMs;
    final stats = _stats.putIfAbsent(
      _sink.currentScreen ?? 'unknown',
      _FrameStats.new,
    );
    stats.total++;
    if (worst > _budgetMs) stats.slow++;
    if (worst > frozenMs) stats.frozen++;
    if (worst > stats.worstMs) stats.worstMs = worst;
  }

  /// Emits what was counted since the last call, then starts over.
  void report() {
    for (final MapEntry(key: screen, value: stats) in _stats.entries) {
      if (stats.total == 0) continue;
      final tags = {Attr.screenName: screen};
      _sink
        ..recordMetric('ui.frames.total', stats.total.toDouble(),
            type: MetricType.counter, tags: tags)
        ..recordMetric('ui.frames.slow', stats.slow.toDouble(),
            type: MetricType.counter, tags: tags)
        ..recordMetric('ui.frames.frozen', stats.frozen.toDouble(),
            type: MetricType.counter, tags: tags)
        ..recordMetric('ui.frame.jank_ratio', stats.slow / stats.total,
            tags: tags)
        ..recordMetric('ui.frame.worst_ms', stats.worstMs, tags: tags);
    }
    _stats.clear();
  }
}
