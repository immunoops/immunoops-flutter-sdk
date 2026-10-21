import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';

import '../core/diagnostics.dart';
import '../core/telemetry_sink.dart';
import '../network/connectivity_observer.dart';
import 'memory_monitor.dart';

/// Samples memory and battery on a timer and starts the connectivity
/// observer. A plugin that does not answer is skipped from then on.
class DeviceHealthMonitor {
  DeviceHealthMonitor(
    this._sink,
    this._diagnostics, {
    required this.interval,
    required this.memory,
    Battery? battery,
    ConnectivityObserver? connectivity,
  })  : _battery = battery ?? Battery(),
        connectivity =
            connectivity ?? ConnectivityObserver(_sink, _diagnostics);

  final TelemetrySink _sink;
  final DiagnosticsHub _diagnostics;
  final Duration interval;
  final MemoryMonitor memory;
  final ConnectivityObserver connectivity;
  final Battery _battery;

  Timer? _timer;
  bool _batteryOk = true;

  void install() {
    _timer ??= Timer.periodic(interval, (_) => sample());
    unawaited(sample().then((_) => connectivity.start()));
  }

  Future<void> sample() async {
    _sink.markActive('device');
    memory.sample();
    if (!_batteryOk) return;
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (level >= 0) {
        _sink.recordMetric('device.battery.level', level.toDouble(),
            tags: {'battery.state': state.name});
      }
    } on MissingPluginException {
      _batteryOk = false;
      _diagnostics.report(Diagnostics.pluginUnavailable('battery_plus'));
    } catch (_) {
      // The plugin answered that this device has no battery data (a
      // simulator, a desktop): nothing to fix, just skip it.
      _batteryOk = false;
      _diagnostics.trace('bateria indisponível neste aparelho');
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    connectivity.dispose();
  }
}
