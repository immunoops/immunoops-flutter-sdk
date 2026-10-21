import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import '../core/diagnostics.dart';
import '../core/telemetry_sink.dart';

/// The connection type (`wifi`, `mobile`, `none`...) and its changes:
/// `connectivity_change` on every change, plus `network_lost` and
/// `network_restored` (with how long it was down) around an outage.
class ConnectivityObserver {
  ConnectivityObserver(this._sink, this._diagnostics,
      {Connectivity? connectivity, DateTime Function()? now})
      : _connectivity = connectivity ?? Connectivity(),
        _now = now ?? DateTime.now;

  final TelemetrySink _sink;
  final DiagnosticsHub _diagnostics;
  final Connectivity _connectivity;
  final DateTime Function() _now;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _ok = true;
  String? _connection;
  DateTime? _lostAt;

  String? get connection => _connection;

  // The change stream is only opened once a plain query worked: on a
  // platform without the plugin, a failing EventChannel goes straight to
  // FlutterError.onError, where it would look like an error of the app.
  Future<void> start() async {
    await refresh();
    if (!_ok || _subscription != null) return;
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) => update(describe(results)),
      onError: _failed,
    );
  }

  Future<void> refresh() async {
    if (!_ok) return;
    try {
      _connection ??= describe(await _connectivity.checkConnectivity());
    } catch (error) {
      _failed(error);
    }
  }

  /// A new connection type; public so tests can drive it.
  void update(String type) {
    _sink.markActive('device');
    final previous = _connection;
    if (type == previous) return;
    _connection = type;
    if (previous == null) return;
    _sink.recordEvent('connectivity_change', {
      'network.connection.type': type,
      'network.connection.previous_type': previous,
    });
    if (type == 'none') {
      _lostAt = _now();
      _sink.recordEvent('network_lost', {
        'network.connection.previous_type': previous,
        if (_sink.currentScreen != null) 'screen.name': _sink.currentScreen,
      });
    } else if (previous == 'none') {
      final lostAt = _lostAt;
      _lostAt = null;
      _sink.recordEvent('network_restored', {
        'network.connection.type': type,
        if (lostAt != null)
          'duration_ms': _now().difference(lostAt).inMilliseconds,
      });
    }
  }

  void _failed([Object? error]) {
    if (!_ok) return;
    _ok = false;
    if (error is MissingPluginException) {
      _diagnostics.report(Diagnostics.pluginUnavailable('connectivity_plus'));
    } else {
      _diagnostics.trace('conexão indisponível neste aparelho: $error');
    }
  }

  static String describe(List<ConnectivityResult> results) {
    final names = results
        .where((r) => r != ConnectivityResult.none)
        .map((r) => r.name)
        .toList()
      ..sort();
    return names.isEmpty ? 'none' : names.join('+');
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
