import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../rum/journey_tracker.dart';
import '../rum/screen_tracker.dart';
import 'immunoops_client.dart';
import 'diagnostics.dart';
import 'telemetry_item.dart';
import '../network/network_registry.dart';
import 'immunoops_config.dart';
import 'version.dart';

/// Entry point of the SDK.
///
/// ```dart
/// void main() {
///   ImmunoOps.init(
///     const ImmunoOpsConfig(clientKey: '...', appName: 'cria-app'),
///     appRunner: () => runApp(const App()),
///   );
/// }
/// ```
///
/// Every method is safe to call before [init] or when the SDK is disabled:
/// it does nothing (and, in debug builds, says so once).
abstract final class ImmunoOps {
  static ImmunoOpsClient? _client;
  static bool _warnedUninitialized = false;

  /// The running client, for tests and advanced use.
  @visibleForTesting
  static ImmunoOpsClient? get client => _client;

  /// Starts the SDK. Error hooks and the first-frame timer are installed
  /// before this returns; device info, the disk queue and timers start in
  /// the background, so the app's start-up is not delayed. [appRunner],
  /// when given, runs right after the hooks (usually `runApp`).
  static Future<void> init(
    ImmunoOpsConfig options, {
    FutureOr<void> Function()? appRunner,
    @visibleForTesting ImmunoOpsClient? client,
  }) async {
    if (_client != null) {
      debugPrint('[ImmunoOps] init chamado de novo; a primeira configuração '
          'continua valendo.');
    } else if (options.enabled &&
        options.clientKey.trim().isNotEmpty &&
        options.appName.trim().isNotEmpty) {
      final created = client ?? ImmunoOpsClient(options);
      _client = created;
      activeNetworkRecorder = created.network;
      created.installSync();
      unawaited(created.start());
    } else if (options.enabled) {
      debugPrint('[ImmunoOps] clientKey e appName são '
          'obrigatórios; o SDK ficou desligado.');
    }
    if (appRunner != null) await appRunner();
  }

  /// Completes when the background part of [init] is done.
  static Future<void> get ready => _client?.ready ?? Future.value();

  static ImmunoOpsClient? _running() {
    final client = _client;
    if (client == null && !_warnedUninitialized && kDebugMode) {
      _warnedUninitialized = true;
      debugPrint('${Diagnostics.notInitialized}');
    }
    return client;
  }

  /// A new observer for one navigator. Give one to the root navigator
  /// (GoRouter `observers:` or MaterialApp `navigatorObservers:`) and one
  /// to each ShellRoute; they all report to the same screen tracker.
  static NavigatorObserver get navigatorObserver =>
      ImmunoOpsNavigatorObserver(() => _client?.screens);

  // ---------------------------------------------------------------- metrics

  /// A value at a moment: latency, size, count of something now.
  static void metric(String name, num value, {Map<String, String>? tags}) =>
      _running()?.recordMetric(name, value.toDouble(), tags: tags ?? const {});

  /// Adds [amount] to a counter: things that happened.
  static void increment(String name,
          {num amount = 1, Map<String, String>? tags}) =>
      _running()?.recordMetric(name, amount.toDouble(),
          type: MetricType.counter, tags: tags ?? const {});

  /// Runs [action] and records how long it took as [name], in ms, even
  /// when it throws.
  static Future<T> time<T>(
    String name,
    FutureOr<T> Function() action, {
    Map<String, String>? tags,
  }) async {
    final watch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      _running()?.recordMetric(name, watch.elapsedMicroseconds / 1000,
          tags: tags ?? const {});
    }
  }

  // ------------------------------------------------------------------- logs

  static void log(ImmunoOpsLogLevel level, String message,
          {Map<String, Object?>? context}) =>
      _running()?.recordLog(level, message, context: context ?? const {});

  static void debug(String message, {Map<String, Object?>? context}) =>
      log(ImmunoOpsLogLevel.debug, message, context: context);

  static void info(String message, {Map<String, Object?>? context}) =>
      log(ImmunoOpsLogLevel.info, message, context: context);

  static void warn(String message, {Map<String, Object?>? context}) =>
      log(ImmunoOpsLogLevel.warn, message, context: context);

  /// An error the app caught. Shows up next to the automatic ones, with
  /// the same grouping.
  static void error(Object error,
      [StackTrace? stackTrace, Map<String, Object?>? context]) {
    try {
      _running()?.crash.report(
            error,
            stackTrace ?? StackTrace.current,
            unhandled: false,
            source: 'manual',
            extra: context ?? const {},
          );
    } catch (_) {
      // Called from the app's own catch block: never throw back into it.
    }
  }

  // ----------------------------------------------------------------- events

  /// A business event: `aula_comprada`, `checkout_concluido`...
  static void event(String name, [Map<String, Object?>? payload]) =>
      _running()?.recordEvent(name, payload ?? const {});

  // --------------------------------------------------------------- journeys

  /// Starts a business journey (`checkout.payment`, `aula.reserva`).
  /// Errors and requests until it ends carry its name; its duration and
  /// outcome become `journey.duration_ms`. Keep [attributes] few-valued
  /// (a payment method, a plan), never ids.
  ///
  /// ```dart
  /// final checkout = ImmunoOps.startJourney('checkout.payment',
  ///     attributes: {'payment.method': 'pix'});
  /// try {
  ///   await pay();
  ///   checkout.end();
  /// } catch (e, s) {
  ///   checkout.fail(e, s);
  ///   rethrow;
  /// }
  /// ```
  static ImmunoOpsJourney startJourney(String name,
      {Map<String, String>? attributes}) {
    try {
      return _running()?.journeys.start(name, attributes: attributes) ??
          ImmunoOpsJourney.noop(name);
    } catch (_) {
      return ImmunoOpsJourney.noop(name);
    }
  }

  /// Runs [action] as the journey [name]: success when it returns, failure
  /// (rethrown) when it throws.
  static Future<T> journey<T>(
    String name,
    FutureOr<T> Function() action, {
    Map<String, String>? attributes,
  }) async {
    final run = startJourney(name, attributes: attributes);
    try {
      final result = await action();
      run.end();
      return result;
    } catch (error, stack) {
      run.fail(error, stack);
      rethrow;
    }
  }

  // ---------------------------------------------------------------- context

  /// Names the current screen when navigation does not go through a
  /// navigator the SDK observes (tabs, page views).
  static void setScreen(String name) => _running()?.screens.enter(name);

  /// A tag on everything from now on; pass null to remove it. Keep values
  /// few (a plan, a flag), never a user id.
  static void setGlobalTag(String key, String? value) =>
      _running()?.setGlobalTag(key, value);

  /// With `requireConsent: true`, nothing is collected until this is
  /// called with true. False stops collection and deletes what is queued.
  static Future<void> setConsent(bool granted) async =>
      _running()?.setConsent(granted);

  // ------------------------------------------------------------- lifecycle

  /// Sends everything queued now.
  static Future<void> flush() async => _client?.buffer.flush(force: true);

  /// What is live and what is wrong; also printed in debug builds.
  static ImmunoOpsDiagnostics diagnostics() =>
      _client?.report() ??
      ImmunoOpsDiagnostics(
        initialized: false,
        sdkVersion: sdkVersion,
        captures: const {},
        issues: const [Diagnostics.notInitialized],
        queued: 0,
        sent: 0,
        dropped: 0,
      );

  /// Sends what is left and stops every capture. Mostly for tests.
  static Future<void> shutdown() async {
    final client = _client;
    _client = null;
    activeNetworkRecorder = null;
    _warnedUninitialized = false;
    await client?.shutdown();
  }
}
