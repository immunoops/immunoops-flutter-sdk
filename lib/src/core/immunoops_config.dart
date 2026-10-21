/// Which automatic captures run. Every capture is on by default; turn one
/// off when the app already measures that signal with another tool.
class ImmunoOpsCaptures {
  const ImmunoOpsCaptures({
    this.errors = true,
    this.navigation = true,
    this.frames = true,
    this.startup = true,
    this.network = true,
    this.device = true,
    this.sessions = true,
  });

  /// Captures nothing automatically; only the manual API sends data.
  const ImmunoOpsCaptures.none()
      : errors = false,
        navigation = false,
        frames = false,
        startup = false,
        network = false,
        device = false,
        sessions = false;

  final bool errors;
  final bool navigation;
  final bool frames;
  final bool startup;
  final bool network;
  final bool device;
  final bool sessions;

  Map<String, bool> toMap() => {
        'errors': errors,
        'navigation': navigation,
        'frames': frames,
        'startup': startup,
        'network': network,
        'device': device,
        'sessions': sessions,
      };
}

/// Share of each kind of data that is kept, from 0 (nothing) to 1 (all).
/// Error logs are never sampled out.
class ImmunoOpsSampling {
  const ImmunoOpsSampling({
    this.metrics = 1,
    this.logs = 1,
    this.events = 1,
    this.network = 1,
  })  : assert(metrics >= 0 && metrics <= 1),
        assert(logs >= 0 && logs <= 1),
        assert(events >= 0 && events <= 1),
        assert(network >= 0 && network <= 1);

  final double metrics;
  final double logs;
  final double events;

  /// Applies to automatic HTTP measurements only.
  final double network;
}

/// Configuration for [ImmunoOps.init].
class ImmunoOpsConfig {
  const ImmunoOpsConfig({
    required this.clientKey,
    required this.appName,
    this.environment = 'production',
    this.endpoint = defaultEndpoint,
    this.captures = const ImmunoOpsCaptures(),
    this.sampling = const ImmunoOpsSampling(),
    this.traceHosts = const [],
    this.flushInterval = const Duration(seconds: 10),
    this.maxBatchSize = 100,
    this.maxQueueSize = 2000,
    this.deviceInterval = const Duration(seconds: 60),
    this.sessionTimeout = const Duration(minutes: 30),
    this.journeyTimeout = const Duration(minutes: 10),
    this.sanitizePii = true,
    this.requireConsent = false,
    this.enabled = true,
    this.debug = false,
  })  : assert(maxBatchSize > 0),
        assert(maxQueueSize >= maxBatchSize);

  /// The ingest base the console shows next to the key, without `/v1/...`.
  static const defaultEndpoint = 'https://aegis.funccloud.com/agent/ingest';

  /// The key from the Instrumentation screen of the Immuno Ops console.
  final String clientKey;

  /// The name the app is listed under in the console.
  final String appName;

  /// `production`, `staging`, `development`...
  final String environment;

  /// The ingest base the console shows; `/v1/custom` is appended.
  final String endpoint;

  final ImmunoOpsCaptures captures;
  final ImmunoOpsSampling sampling;

  /// Hosts that receive a W3C `traceparent` header on outgoing requests.
  /// Empty by default: an unexpected header on a third-party API can break
  /// its CORS preflight on the web.
  final List<String> traceHosts;

  /// How often queued data is sent.
  final Duration flushInterval;

  /// Items per request; reaching it also sends right away.
  final int maxBatchSize;

  /// Items kept in memory and on disk; the oldest go first when it is full.
  final int maxQueueSize;

  /// How often memory, battery and connection are sampled.
  final Duration deviceInterval;

  /// Time in background after which the next foreground starts a session.
  final Duration sessionTimeout;

  /// A journey still open after this long counts as abandoned.
  final Duration journeyTimeout;

  /// Masks CPF, card numbers, tokens and sensitive keys before sending.
  final bool sanitizePii;

  /// When true nothing is collected until [ImmunoOps.setConsent] is called
  /// with `true`.
  final bool requireConsent;

  /// When false the SDK does nothing at all.
  final bool enabled;

  /// Prints each batch and every diagnostic to the debug console.
  final bool debug;

  Uri get ingestUri {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    return Uri.parse(base.endsWith('/v1/custom') ? base : '$base/v1/custom');
  }
}
