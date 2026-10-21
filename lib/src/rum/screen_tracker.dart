import 'package:flutter/widgets.dart';

import '../core/semconv.dart';
import '../core/telemetry_sink.dart';
import 'route_template.dart';

/// The screen the user is on and since when. One per app: every navigator
/// observer (root and each ShellRoute) feeds the same tracker, so a
/// rebuilt MaterialApp or a nested navigator never double-counts.
class ScreenTracker {
  ScreenTracker(this._sink, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final TelemetrySink _sink;
  final DateTime Function() _now;
  String? _screen;
  DateTime? _enteredAt;

  String? get screen => _screen;

  void enter(String name) {
    _sink.markActive('navigation');
    if (name == _screen) return;
    _closeCurrent();
    _sink.recordEvent('screen_view', {
      Attr.screenName: name,
      if (_screen != null) 'screen.previous_name': _screen,
    });
    _screen = name;
    _enteredAt = _now();
    _sink.currentScreen = name;
  }

  void _closeCurrent() {
    final screen = _screen;
    final enteredAt = _enteredAt;
    if (screen == null || enteredAt == null) return;
    _sink.recordMetric(
      'ui.screen.duration_ms',
      _now().difference(enteredAt).inMilliseconds.toDouble(),
      tags: {Attr.screenName: screen},
    );
  }

  /// Closes the current screen's time when the app goes to background.
  void pause() {
    _closeCurrent();
    _enteredAt = null;
  }

  /// Restarts the current screen's time when the app comes back.
  void resume() {
    if (_screen != null) _enteredAt = _now();
  }
}

/// Reports each page route to the [ScreenTracker]. Dialogs and sheets are
/// not screens: only [PageRoute]s count. A navigator takes one observer
/// instance, so `ImmunoOps.navigatorObserver` hands out a new one each
/// time; give one to the root navigator and one to each ShellRoute.
class ImmunoOpsNavigatorObserver extends NavigatorObserver {
  ImmunoOpsNavigatorObserver(this._tracker);

  final ScreenTracker? Function() _tracker;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _enter(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _enter(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute && previousRoute != null) _enter(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute && previousRoute != null) _enter(previousRoute);
  }

  void _enter(Route<dynamic> route) {
    if (route is! PageRoute) return;
    _tracker()?.enter(
      screenNameFrom(route.settings.name) ?? route.runtimeType.toString(),
    );
  }
}
