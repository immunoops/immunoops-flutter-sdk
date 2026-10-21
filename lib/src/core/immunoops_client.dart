import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../crash/crash_reporter.dart';
import '../exporter/ingest_exporter.dart';
import '../exporter/telemetry_buffer.dart';
import '../exporter/telemetry_store.dart';
import '../network/network_recorder.dart';
import '../performance/device_health_monitor.dart';
import '../performance/frame_monitor.dart';
import '../performance/memory_monitor.dart';
import '../performance/startup_monitor.dart';
import '../rum/journey_tracker.dart';
import '../rum/screen_tracker.dart';
import 'context/app_context.dart';
import 'diagnostics.dart';
import 'immunoops_config.dart';
import 'lifecycle/session_manager.dart';
import 'privacy/data_sanitizer.dart';
import 'telemetry_item.dart';
import 'telemetry_sink.dart';
import 'version.dart';

/// Everything one `ImmunoOps.init` sets up. The public [ImmunoOps] facade
/// holds a single instance; tests build their own.
class ImmunoOpsClient with WidgetsBindingObserver implements TelemetrySink {
  ImmunoOpsClient(
    this.options, {
    TelemetryStore? store,
    http.Client? httpClient,
    AppContext? attributes,
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random(),
        _fixedAttributes = attributes,
        diagnostics = DiagnosticsHub(verbose: options.debug) {
    _store = store ?? TelemetryStore.platform();
    buffer = TelemetryBuffer(
      transport: IngestExporter(
        uri: options.ingestUri,
        clientKey: options.clientKey,
        client: httpClient,
      ),
      store: _store,
      appName: options.appName,
      diagnostics: diagnostics,
      maxBatchSize: options.maxBatchSize,
      maxQueueSize: options.maxQueueSize,
      flushInterval: options.flushInterval,
      now: _now,
    );
    network = NetworkRecorder(
      this,
      ingestUri: options.ingestUri,
      traceHosts: options.traceHosts,
    );
    screens = ScreenTracker(this, now: _now);
    crash = CrashReporter(this, now: _now);
    frames = FrameMonitor(this);
    startup = StartupMonitor(this);
    memory = MemoryMonitor(this);
    sessions = SessionManager(this,
        timeout: options.sessionTimeout,
        emitEvents: options.captures.sessions,
        now: _now);
    journeys = JourneyTracker(this, timeout: options.journeyTimeout, now: _now);
    _consent = !options.requireConsent;
  }

  final ImmunoOpsConfig options;
  final DiagnosticsHub diagnostics;
  final DateTime Function() _now;
  final Random _random;
  final AppContext? _fixedAttributes;
  late final TelemetryStore _store;
  late final TelemetryBuffer buffer;
  late final NetworkRecorder network;
  late final ScreenTracker screens;
  late final CrashReporter crash;
  late final FrameMonitor frames;
  late final StartupMonitor startup;
  late final MemoryMonitor memory;
  late final SessionManager sessions;
  late final JourneyTracker journeys;
  DeviceHealthMonitor? device;

  AppContext? _attributes;
  String? _installId;
  final _early = <TelemetryItem>[];
  final _globalTags = <String, String>{};
  final _active = <String>{};
  bool _consent = true;
  bool _started = false;
  bool _stopped = false;
  Timer? _tick;
  Timer? _selfCheck;
  final _ready = Completer<void>();

  @override
  String? currentScreen;

  @override
  String? get currentJourney => journeys.current;

  @override
  String? get sessionId => sessions.id;

  Future<void> get ready => _ready.future;
  bool get consent => _consent;

  // ---------------------------------------------------------------- start

  /// The synchronous part: hooks that must exist before the first frame.
  void installSync() {
    WidgetsFlutterBinding.ensureInitialized();
    final captures = options.captures;
    if (captures.errors) crash.install();
    if (captures.frames) frames.install();
    if (captures.startup) startup.start();
    WidgetsBinding.instance.addObserver(this);
    if (!_consent) diagnostics.report(Diagnostics.consentPending);
  }

  /// The asynchronous part, off the start-up path: attributes, the disk
  /// queue, timers. Items recorded meanwhile wait in memory.
  Future<void> start() async {
    try {
      _installId = await _loadInstallId();
      _attributes = _fixedAttributes ??
          await AppContext.collect(
            appName: options.appName,
            environment: options.environment,
            diagnostics: diagnostics,
          );
      await buffer.start(autoFlush: false);
      _started = true;
      final early = List.of(_early);
      _early.clear();
      for (final item in early) {
        buffer.add(_enrich(item));
      }
      if (options.captures.device) {
        device = DeviceHealthMonitor(this, diagnostics,
            interval: options.deviceInterval, memory: memory)
          ..install();
      }
      sessions.start();
      _tick = Timer.periodic(options.flushInterval, (_) => tick());
      _selfCheck = Timer(const Duration(seconds: 30), selfCheck);
    } catch (error) {
      diagnostics.report(ImmunoOpsDiagnostic(
        code: 'IMMUNO-E005',
        severity: DiagnosticSeverity.error,
        message: 'Falha ao iniciar o SDK: $error',
        fix: 'Rode dart run immunoops_flutter:doctor e confira o setup.',
      ));
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<String> _loadInstallId() async {
    try {
      final stored = await _store.readInstallId();
      if (stored != null) return stored;
      final id = randomId();
      await _store.writeInstallId(id);
      return id;
    } catch (_) {
      return randomId();
    }
  }

  /// Frame counts first, then everything queued goes out.
  Future<void> tick() async {
    if (options.captures.frames) frames.report();
    journeys.expire();
    await buffer.flush();
  }

  // ------------------------------------------------------------- lifecycle

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (!sessions.background()) return;
        screens.pause();
        // The OS may kill a backgrounded app without notice: send now and
        // keep the rest on disk.
        if (options.captures.frames) frames.report();
        unawaited(buffer.flush(force: true).then((_) => buffer.persist()));
      case AppLifecycleState.resumed:
        if (!sessions.inBackground) return;
        if (sessions.foreground()) journeys.abandonAll();
        screens.resume();
        if (options.captures.startup) startup.resumed();
      case AppLifecycleState.detached:
        unawaited(buffer.persist());
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (options.captures.device) memory.onPressure();
  }

  // ------------------------------------------------------------- recording

  @override
  void markActive(String capture) => _active.add(capture);

  @override
  void recordMetric(
    String name,
    double value, {
    MetricType type = MetricType.gauge,
    Map<String, String> tags = const {},
    bool network = false,
  }) {
    if (!value.isFinite) return;
    final rate = network ? options.sampling.network : options.sampling.metrics;
    if (!_sampled(rate)) return;
    _accept(MetricItem(
      name: name,
      value: value,
      type: type,
      tags: options.sanitizePii
          ? {for (final e in tags.entries) e.key: _cleanTag(e.key, e.value)}
          : tags,
      timestampMs: _now().millisecondsSinceEpoch,
    ));
  }

  @override
  void recordLog(
    ImmunoOpsLogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) {
    if (level != ImmunoOpsLogLevel.error && !_sampled(options.sampling.logs)) {
      return;
    }
    final safe = jsonSafeMap(context);
    _accept(LogItem(
      level: level,
      message: options.sanitizePii ? sanitizeString(message) : message,
      context: options.sanitizePii ? sanitizeMap(safe) : safe,
      timestampMs: _now().millisecondsSinceEpoch,
    ));
  }

  @override
  void recordEvent(String name, [Map<String, Object?> payload = const {}]) {
    if (!_sampled(options.sampling.events)) return;
    final safe = jsonSafeMap(payload);
    _accept(EventItem(
      name: name,
      payload: options.sanitizePii ? sanitizeMap(safe) : safe,
      timestampMs: _now().millisecondsSinceEpoch,
    ));
  }

  String _cleanTag(String key, String value) =>
      isSensitiveKey(key) ? redacted : sanitizeString(value);

  bool _sampled(double rate) =>
      rate >= 1 || (rate > 0 && _random.nextDouble() < rate);

  void _accept(TelemetryItem item) {
    if (_stopped || !_consent) return;
    if (!_started) {
      if (_early.length < options.maxQueueSize) _early.add(item);
      return;
    }
    buffer.add(_enrich(item));
  }

  TelemetryItem _enrich(TelemetryItem item) {
    final attributes = _attributes;
    if (attributes == null) return item;
    final context = {
      ...attributes.context(sessionId: sessions.id, installId: _installId),
      ..._globalTags,
    };
    return switch (item) {
      MetricItem() => MetricItem(
          name: item.name,
          value: item.value,
          type: item.type,
          tags: {...attributes.metricTags, ..._globalTags, ...item.tags},
          timestampMs: item.timestampMs,
        ),
      LogItem() => LogItem(
          level: item.level,
          message: item.message,
          context: {...context, ...item.context},
          timestampMs: item.timestampMs,
        ),
      EventItem() => EventItem(
          name: item.name,
          payload: {...context, ...item.payload},
          timestampMs: item.timestampMs,
        ),
    };
  }

  /// A tag added to every metric, log and event from now on. Keep values
  /// few (a plan, a feature flag), never an id.
  void setGlobalTag(String key, String? value) {
    if (value == null) {
      _globalTags.remove(key);
    } else {
      _globalTags[key] = options.sanitizePii ? _cleanTag(key, value) : value;
    }
  }

  Future<void> setConsent(bool granted) async {
    _consent = granted;
    if (granted) {
      diagnostics.clear('IMMUNO-I201');
    } else {
      _early.clear();
      await buffer.clear();
    }
  }

  // ----------------------------------------------------------- self-check

  /// After 30 s, checks that every capture the app turned on has seen
  /// activity, then sends the handshake the console uses to show what is
  /// missing.
  void selfCheck() {
    final captures = options.captures;
    if (captures.navigation && !_active.contains('navigation')) {
      diagnostics.report(Diagnostics.observerMissing);
    }
    if (captures.network && !_active.contains('network')) {
      diagnostics.report(Diagnostics.networkMissing);
    }
    if (captures.errors && crash.overridden) {
      diagnostics.report(Diagnostics.handlerReplaced);
    }
    recordEvent('immunoops.sdk_handshake', {
      'sdk.version': sdkVersion,
      'captures.configured': captures.toMap(),
      'captures.active': {
        for (final name in captures.toMap().keys) name: _active.contains(name),
      },
      'issues': [for (final issue in diagnostics.issues) issue.code],
      'config.flush_interval_s': options.flushInterval.inSeconds,
      'config.sampling.metrics': options.sampling.metrics,
      'config.sampling.network': options.sampling.network,
      'config.require_consent': options.requireConsent,
    });
  }

  ImmunoOpsDiagnostics report() => ImmunoOpsDiagnostics(
        initialized: true,
        sdkVersion: sdkVersion,
        captures: {
          for (final MapEntry(key: name, value: on)
              in options.captures.toMap().entries)
            name: on && _active.contains(name),
        },
        issues: diagnostics.issues,
        queued: buffer.queued + _early.length,
        sent: buffer.sent,
        dropped: buffer.dropped,
      );

  // ------------------------------------------------------------- shutdown

  Future<void> shutdown() async {
    if (_stopped) return;
    if (options.captures.frames) frames.report();
    _stopped = true;
    _tick?.cancel();
    _selfCheck?.cancel();
    device?.dispose();
    frames.uninstall();
    crash.uninstall();
    WidgetsBinding.instance.removeObserver(this);
    await buffer.shutdown();
  }
}
