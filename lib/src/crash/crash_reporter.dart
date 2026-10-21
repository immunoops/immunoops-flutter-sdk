import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../core/semconv.dart';
import '../core/telemetry_item.dart';
import '../core/telemetry_sink.dart';
import 'crash_fingerprint.dart';

/// Installs the two global error hooks Flutter offers, keeping whatever
/// handler the app (or another SDK) set before: framework errors through
/// [FlutterError.onError], everything else through
/// [PlatformDispatcher.onError]. No zone is used, so there is no
/// "Zone mismatch" with a binding the app initialised earlier.
class CrashReporter {
  CrashReporter(this._sink, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final TelemetrySink _sink;
  final DateTime Function() _now;
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  FlutterExceptionHandler? _ownFlutter;
  ErrorCallback? _ownPlatform;
  bool _installed = false;

  /// Same error over and over (a build error repeats every frame): at most
  /// [_perMinute] reports per fingerprint per minute.
  static const _perMinute = 5;
  final _recent = <String, List<DateTime>>{};

  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutter = FlutterError.onError;
    FlutterError.onError = _ownFlutter = (details) {
      _guard(() => report(
            details.exception,
            details.stack,
            unhandled: false,
            source: 'flutter',
            library: details.library,
            context: _describe(details),
          ));
      (_previousFlutter ?? FlutterError.presentError)(details);
    };
    _previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = _ownPlatform = (error, stack) {
      _guard(() =>
          report(error, stack, unhandled: true, source: 'platform_dispatcher'));
      return _previousPlatform?.call(error, stack) ?? false;
    };
    _sink.markActive('errors');
  }

  /// Puts back the handlers that were there before, unless someone else
  /// replaced ours since (then theirs stays).
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (FlutterError.onError == _ownFlutter) {
      FlutterError.onError = _previousFlutter;
    }
    if (PlatformDispatcher.instance.onError == _ownPlatform) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
  }

  /// Whether a handler set after install() replaced ours.
  bool get overridden =>
      _installed &&
      (FlutterError.onError != _ownFlutter ||
          PlatformDispatcher.instance.onError != _ownPlatform);

  void report(
    Object error,
    StackTrace? stack, {
    required bool unhandled,
    required String source,
    String? library,
    String? context,
    Map<String, Object?> extra = const {},
  }) {
    final type = error.runtimeType.toString();
    final message = _firstLine(_safeString(error));
    final fingerprint = crashFingerprint(type, message, stack);
    if (!_allow(fingerprint)) return;
    final journey = _sink.currentJourney;
    _sink.recordLog(
      ImmunoOpsLogLevel.error,
      '$type: $message',
      context: {
        // A Dart error does not end the process: "crash" here means nothing
        // in the app caught it.
        Attr.eventType: unhandled ? EventType.crash : EventType.error,
        Attr.exceptionType: type,
        Attr.exceptionMessage: message,
        Attr.exceptionUnhandled: unhandled,
        Attr.exceptionSource: source,
        Attr.exceptionFingerprint: fingerprint,
        if (library != null) Attr.flutterLibrary: library,
        if (context != null) Attr.flutterContext: context,
        if (stack != null)
          Attr.exceptionStacktrace: _limit(_safeString(stack), 8000),
        if (_sink.currentScreen != null) Attr.screenName: _sink.currentScreen,
        if (journey != null) Attr.journeyName: journey,
        ...extra,
      },
    );
  }

  /// Whatever goes wrong while recording stays here: the app's own handler
  /// must run anyway.
  static void _guard(void Function() action) {
    try {
      action();
    } catch (_) {}
  }

  static String? _describe(FlutterErrorDetails details) {
    try {
      return details.context?.toDescription();
    } catch (_) {
      return null;
    }
  }

  /// Like '$value', for objects whose toString throws.
  static String _safeString(Object value) {
    try {
      return value.toString();
    } catch (_) {
      return Error.safeToString(value);
    }
  }

  bool _allow(String fingerprint) {
    final now = _now();
    final times = _recent.putIfAbsent(fingerprint, () => [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (times.length >= _perMinute) return false;
    times.add(now);
    if (_recent.length > 200) _recent.remove(_recent.keys.first);
    return true;
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return _limit(line, 300);
  }

  static String _limit(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}…' : text;
}
