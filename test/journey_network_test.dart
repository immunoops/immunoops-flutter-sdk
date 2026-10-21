import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/src/core/lifecycle/session_manager.dart';
import 'package:immunoops_flutter/src/core/telemetry_item.dart';
import 'package:immunoops_flutter/src/crash/crash_reporter.dart';
import 'package:immunoops_flutter/src/exporter/retry_policy.dart';
import 'package:immunoops_flutter/src/network/connectivity_observer.dart';
import 'package:immunoops_flutter/src/core/diagnostics.dart';
import 'package:immunoops_flutter/src/network/http_error_classifier.dart';
import 'package:immunoops_flutter/src/network/immunoops_dio_interceptor.dart';
import 'package:immunoops_flutter/src/network/immunoops_http_client.dart';
import 'package:immunoops_flutter/src/network/network_recorder.dart';
import 'package:immunoops_flutter/src/performance/memory_monitor.dart';
import 'package:immunoops_flutter/src/performance/startup_monitor.dart';
import 'package:immunoops_flutter/src/rum/journey_tracker.dart';

import 'support/fake_sink.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.error, this.type});

  final int status;
  final Object? error;
  final DioExceptionType? type;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (type != null) {
      throw DioException(requestOptions: options, type: type!, error: error);
    }
    return ResponseBody.fromString('{}', status);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeSink sink;
  late DateTime now;

  setUp(() {
    sink = FakeSink()..currentScreen = 'checkout';
    now = DateTime(2026, 10, 19, 9);
  });

  group('journeys', () {
    late JourneyTracker journeys;

    setUp(() => journeys = JourneyTracker(sink,
        timeout: const Duration(minutes: 10), now: () => now));

    test('a successful journey records its duration and outcome', () {
      final run = journeys
          .start('checkout.payment', attributes: {'payment.method': 'pix'});
      expect(journeys.current, 'checkout.payment');
      now = now.add(const Duration(milliseconds: 4800));
      run.end();
      run.fail(StateError('ignored: already finished'));

      final metric = sink.named('journey.duration_ms').single;
      expect(metric.value, 4800);
      expect(metric.tags, {
        'journey.name': 'checkout.payment',
        'journey.outcome': 'success',
        'payment.method': 'pix',
      });
      expect(sink.events.map((e) => e.name), ['journey_start', 'journey_end']);
      expect(sink.logs, isEmpty);
      expect(journeys.current, isNull);
    });

    test('a failed journey logs the error with the PDF fields', () {
      final run = journeys.start('checkout.payment');
      now = now.add(const Duration(seconds: 2));
      run.fail(const SocketException('Read timed out'), StackTrace.current);
      final log = sink.logs.single;
      expect(log.level, ImmunoOpsLogLevel.error);
      expect(log.context['event.type'], 'mobile.journey.failure');
      expect(log.context['journey.name'], 'checkout.payment');
      expect(log.context['journey.outcome'], 'failure');
      expect(log.context['exception.type'], 'SocketException');
      expect(log.context['duration_ms'], 2000);
      expect(log.context['screen.name'], 'checkout');
    });

    test('open journeys expire as abandoned, and a new session abandons all',
        () {
      journeys.start('checkout.payment');
      now = now.add(const Duration(minutes: 11));
      journeys.start('aula.reserva');
      journeys.expire();
      expect(sink.named('journey.duration_ms').single.tags['journey.outcome'],
          'abandoned');
      journeys.abandonAll();
      expect(
          sink.named('journey.duration_ms').map((m) => m.tags['journey.name']),
          ['checkout.payment', 'aula.reserva']);
      expect(journeys.current, isNull);
    });

    test('errors and requests inside a journey carry its name', () async {
      sink.currentJourney = 'checkout.payment';
      CrashReporter(sink)
          .report(StateError('x'), null, unhandled: false, source: 't');
      expect(sink.logs.single.context['journey.name'], 'checkout.payment');

      final recorder = NetworkRecorder(sink,
          ingestUri: Uri.parse('https://i.io/v1/custom'), traceHosts: const []);
      await (Dio()
            ..httpClientAdapter = _Adapter()
            ..interceptors.add(ImmunoOpsDioInterceptor.withRecorder(recorder)))
          .post<void>('https://api.cria.com/payments');
      expect(
          sink
              .named('http.client.request.duration_ms')
              .single
              .tags['journey.name'],
          'checkout.payment');
    });
  });

  group('network failures (PDF list)', () {
    late NetworkRecorder recorder;

    setUp(() => recorder = NetworkRecorder(sink,
        ingestUri: Uri.parse('https://i.io/v1/custom'),
        traceHosts: const ['api.cria.com']));

    Future<void> call(_Adapter adapter) async {
      final dio = Dio()
        ..httpClientAdapter = adapter
        ..interceptors.add(ImmunoOpsDioInterceptor.withRecorder(recorder));
      try {
        await dio.post<void>('https://api.cria.com/payments');
      } on DioException {
        // The app sees the same failure it would see without the SDK.
      }
    }

    test('DNS, TLS, timeout and connection errors are told apart', () async {
      await call(_Adapter(
          type: DioExceptionType.connectionError,
          error: const SocketException(
              "Failed host lookup: 'api.cria.com' (OS Error: nodename nor servname provided)")));
      await call(_Adapter(
          type: DioExceptionType.unknown,
          error: const HandshakeException('Handshake error in client')));
      await call(_Adapter(type: DioExceptionType.badCertificate));
      await call(_Adapter(type: DioExceptionType.receiveTimeout));
      await call(_Adapter(
          type: DioExceptionType.connectionError,
          error: const SocketException('Connection refused')));
      expect(
        sink
            .named('http.client.request.duration_ms')
            .map((m) => m.tags['error.type']),
        ['dns_error', 'tls_error', 'tls_error', 'timeout', 'connection_error'],
      );
      expect(sink.logs.map((l) => l.level).toSet(), {ImmunoOpsLogLevel.error});
      expect(sink.logs.first.context['event.type'], 'mobile.network.error');
      expect(sink.logs.first.context['exception.type'], 'SocketException');
      expect(sink.logs.first.context['trace_id'], hasLength(32));
    });

    test('5xx is an error, 429 a warning, 401 only a metric (Dio)', () async {
      for (final status in [504, 429, 401]) {
        await call(_Adapter(status: status));
      }
      expect(
          sink
              .named('http.client.request.duration_ms')
              .map((m) => m.tags['http.response.status_code']),
          ['504', '429', '401']);
      expect(sink.logs.map((l) => l.level),
          [ImmunoOpsLogLevel.error, ImmunoOpsLogLevel.warn]);
    });

    test('status codes from real responses', () async {
      final client = ImmunoOpsHttpClient.withRecorder(
        recorder,
        MockClient((request) async =>
            http.Response('', int.parse(request.url.pathSegments.last))),
      );
      for (final status in [504, 429, 401]) {
        await client.get(Uri.parse('https://api.cria.com/s/$status'));
      }
      expect(
          sink
              .named('http.client.request.duration_ms')
              .map((m) => m.tags['error.type']),
          ['504', '429', '401']);
      expect(
          sink.logs
              .map((l) => (l.level, l.context['http.response.status_code'])),
          [(ImmunoOpsLogLevel.error, '504'), (ImmunoOpsLogLevel.warn, '429')]);
    });

    test('the http client tells DNS from other failures too', () async {
      final client = ImmunoOpsHttpClient.withRecorder(
        recorder,
        MockClient((_) async => throw http.ClientException(
            'Failed host lookup: api.cria.com',
            Uri.parse('https://api.cria.com/x?token=abc'))),
      );
      await expectLater(client.get(Uri.parse('https://api.cria.com/x')),
          throwsA(isA<http.ClientException>()));
      expect(
          sink
              .named('http.client.request.duration_ms')
              .single
              .tags['error.type'],
          'dns_error');
    });

    test('no tracestate without a session', () {
      sink.sessionId = null;
      expect(recorder.traceFor(Uri.parse('https://api.cria.com/x'))!.tracestate,
          isNull);
      sink.sessionId = 'abc';
      expect(recorder.traceFor(Uri.parse('https://api.cria.com/x'))!.headers,
          containsPair('tracestate', 'immunoops=s:abc'));
      expect(recorder.traceFor(Uri.parse('https://other.com/x')), isNull);
    });

    test('classifier on plain values', () {
      expect(HttpErrorClassifier.classify(null), HttpFailure.unknown);
      expect(HttpErrorClassifier.classify(Exception('Connection timed out')),
          HttpFailure.timeout);
      expect(HttpErrorClassifier.classify(const TlsException('bad cert')),
          HttpFailure.tls);
    });
  });

  test('memory pressure: one event and warning a minute', () {
    sink.currentJourney = 'checkout.payment';
    MemoryMonitor(sink)
      ..onPressure()
      ..onPressure();
    expect(sink.events.single.name, 'memory_pressure');
    expect(sink.logs.single.level, ImmunoOpsLogLevel.warn);
    expect(sink.logs.single.context['event.type'], 'mobile.memory.pressure');
    expect(sink.logs.single.context['journey.name'], 'checkout.payment');
    expect(sink.logs.single.context['app.memory.rss_mb'], isA<int>());
  });

  test('network lost and restored', () {
    final observer = ConnectivityObserver(sink, DiagnosticsHub(verbose: false),
        now: () => now)
      ..update('wifi');
    observer.update('none');
    now = now.add(const Duration(seconds: 30));
    observer.update('mobile');
    expect(sink.events.map((e) => e.name), [
      'connectivity_change',
      'network_lost',
      'connectivity_change',
      'network_restored'
    ]);
    expect(sink.events.last.payload['duration_ms'], 30000);
    expect(sink.events.last.payload['network.connection.type'], 'mobile');
  });

  testWidgets('warm start: from resume to the next frame', (tester) async {
    final startup = StartupMonitor(sink);
    startup.resumed();
    await tester.pump();
    expect(sink.metrics, isEmpty, reason: 'no warm start before the cold one');
    startup.markColdDone();
    startup.resumed();
    tester.binding.scheduleFrame();
    await tester.pump();
    final metric = sink.named('app.startup.duration_ms').single;
    expect(metric.tags, {'startup.type': 'warm'});
  });

  test('retry policy: 5 s doubling to 5 min, plus up to 20 %', () {
    const policy = RetryPolicy();
    final random = Random(3);
    Duration at(int n) => policy.delay(n, random);
    expect(at(1).inMilliseconds, inInclusiveRange(5000, 6000));
    expect(at(2).inMilliseconds, inInclusiveRange(10000, 12000));
    expect(at(30).inMilliseconds, inInclusiveRange(300000, 360000));
  });

  test('sessions: a long absence links the new session to the old one', () {
    final sessions = SessionManager(sink,
        timeout: const Duration(minutes: 30), now: () => now)
      ..start();
    final first = sessions.id;
    sessions.background();
    now = now.add(const Duration(minutes: 31));
    expect(sessions.foreground(), isTrue);
    expect(sink.events.last.name, 'session_start');
    expect(sink.events.last.payload['session.previous_id'], first);

    final quiet = FakeSink();
    SessionManager(quiet,
        timeout: const Duration(minutes: 30), emitEvents: false)
      ..start()
      ..background()
      ..foreground();
    expect(quiet.events, isEmpty);
  });
}
