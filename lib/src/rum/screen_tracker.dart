import 'dart:async';

import 'package:flutter/scheduler.dart';
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
///
/// A page with no name (go_router `pageBuilder:`) is named by the Router's
/// location, which go_router updates at different times: before the
/// navigator builds on a push, but only after the frame on `go`, a
/// redirect or a pop (with `optionURLReflectsImperativeAPIs` off, a pop
/// even reports the base location). So a pushed page takes the location
/// right away, anything else takes it after the frame, and each route keeps
/// the name it got, for when a pop brings it back. A `go` (the Router
/// notifies, and no push follows) names the top route again: between pages
/// with no key it reuses the route and calls no observer method at all.
class ImmunoOpsNavigatorObserver extends NavigatorObserver {
  ImmunoOpsNavigatorObserver(this._tracker);

  final ScreenTracker? Function() _tracker;
  final _names = Expando<String>('immunoops.screen');
  Route<dynamic>? _top;
  int _pushes = 0;
  bool _justNavigated = false;
  RouteInformationProvider? _provider;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _navigated();
    _top = route;
    _pushes++;
    if (route is PageRoute &&
        screenNameOf(route.settings) == null &&
        route.settings is Page) {
      final location = _location();
      if (location != null) _names[route] = location;
    }
    _enterLater(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _navigated();
    if (newRoute == null) return;
    if (oldRoute == _top) _top = newRoute;
    _enterLater(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _navigated();
    if (route == _top) _top = previousRoute;
    if (route is PageRoute && previousRoute != null) _enterLater(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _navigated();
    if (route == _top) _top = previousRoute;
    if (route is PageRoute && previousRoute != null) _enterLater(previousRoute);
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _navigated();
    _top = topRoute;
    _enterLater(topRoute);
  }

  /// go_router also notifies right after a pop, with the location it will
  /// report (the base one, with optionURLReflectsImperativeAPIs off): a
  /// notification in the same turn as a navigation is its echo.
  void _navigated() {
    if (_justNavigated) return;
    _justNavigated = true;
    scheduleMicrotask(() => _justNavigated = false);
  }

  void _onLocationChanged() {
    if (_justNavigated) return;
    final pushes = _pushes;
    SchedulerBinding.instance.addPostFrameCallback((_) => Timer.run(() {
          // A push names its own route; this is for go and redirects.
          final top = _top;
          if (_pushes != pushes || top is! PageRoute || !top.isCurrent) return;
          if (screenNameOf(top.settings) != null) return;
          final name = _location();
          if (name == null) return;
          _names[top] = name;
          _tracker()?.enter(name);
        }));
  }

  /// Named routes enter right away; pages with no name after the frame,
  /// once the router has reported where it is.
  void _enterLater(Route<dynamic> route) {
    _listenToRouter();
    if (route is! PageRoute) return;
    final named = screenNameOf(route.settings);
    if (named != null) {
      _tracker()?.enter(named);
      return;
    }
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) => Timer.run(() {
          if (!route.isCurrent) return;
          final settings = route.settings;
          if (settings is! Page) return;
          var name = _names[route];
          if (name == null) {
            name = _location() ?? _pageChildType(settings);
            if (name != null) _names[route] = name;
          }
          if (name != null) _tracker()?.enter(name);
        }));
    scheduler.ensureVisualUpdate();
  }

  void _listenToRouter() {
    if (_provider != null) return;
    try {
      final context = navigator?.context;
      if (context == null || !context.mounted) return;
      _provider = Router.maybeOf(context)?.routeInformationProvider
        ?..addListener(_onLocationChanged);
    } catch (_) {}
  }

  /// The path the app's Router shows (`/aulas/42` → `/aulas/:id`), for apps
  /// on go_router or any other Router; null without one.
  String? _location() {
    try {
      final context = navigator?.context;
      if (context == null || !context.mounted) return null;
      final path =
          Router.maybeOf(context)?.routeInformationProvider?.value.uri.path;
      return path == null || path.isEmpty ? null : screenNameFrom(path);
    } catch (_) {
      return null;
    }
  }
}

/// The screen name a route's settings carry: its name (go_router `builder:`
/// routes, named routes) or a page key that is a path
/// (`key: state.pageKey`). Null for pages with neither; the observer then
/// uses the router's location, or the page widget's type.
String? screenNameOf(RouteSettings settings) {
  final named = screenNameFrom(settings.name);
  if (named != null) return named;
  if (settings is! Page) return null;
  final key = settings.key;
  if (key is ValueKey<String> && key.value.startsWith('/')) {
    return screenNameFrom(key.value);
  }
  return null;
}

/// Last resort: the type of the page's widget (`SplashPage`). MaterialPage,
/// CupertinoPage and go_router's pages all have a `child`.
String? _pageChildType(RouteSettings settings) {
  if (settings is! Page) return null;
  try {
    final Object? child = (settings as dynamic).child;
    return child is Widget ? child.runtimeType.toString() : null;
  } catch (_) {
    return null;
  }
}
