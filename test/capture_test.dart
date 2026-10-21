import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/src/crash/crash_reporter.dart';
import 'package:immunoops_flutter/src/performance/frame_monitor.dart';
import 'package:immunoops_flutter/src/rum/screen_tracker.dart';
import 'package:immunoops_flutter/src/core/telemetry_item.dart';
import 'package:immunoops_flutter/src/network/immunoops_dio_interceptor.dart';
import 'package:immunoops_flutter/src/network/immunoops_http_client.dart';
import 'package:immunoops_flutter/src/network/network_recorder.dart';

import 'support/fake_sink.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, {this.throwType});

  final int status;
  final DioExceptionType? throwType;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (throwType != null) {
      throw DioException(requestOptions: options, type: throwType!);
    }
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('navigation', () {
    late FakeSink sink;
    late ScreenTracker tracker;
    late DateTime now;

    setUp(() {
      sink = FakeSink();
      now = DateTime(2026);
      tracker = ScreenTracker(sink, now: () => now);
    });

    test('a route name or a path key names the screen', () {
      expect(
          screenNameOf(const RouteSettings(name: '/aulas/42')), '/aulas/:id');
      expect(
          screenNameOf(
              const _Page(key: ValueKey('/aulas/42'), child: Text('x'))),
          '/aulas/:id');
      // go_router's hash page keys are not paths.
      expect(screenNameOf(const _Page(key: ValueKey('1234'), child: Text('x'))),
          isNull);
      expect(screenNameOf(const RouteSettings()), isNull);
    });

    for (final reflect in [false, true]) {
      testWidgets(
          'go_router pages with no name are named by location '
          '(optionURLReflectsImperativeAPIs: $reflect)', (tester) async {
        GoRouter.optionURLReflectsImperativeAPIs = reflect;
        addTearDown(() => GoRouter.optionURLReflectsImperativeAPIs = false);
        // No key and no name, like most apps' pageBuilder pages.
        Page<void> page() =>
            // ignore: prefer_const_constructors
            NoTransitionPage<void>(child: const _Wrapper());
        final router = GoRouter(
          observers: [ImmunoOpsNavigatorObserver(() => tracker)],
          redirect: (_, state) =>
              state.matchedLocation == '/antiga' ? '/nova' : null,
          routes: [
            for (final path in ['/', '/aulas/:id', '/perfil', '/nova'])
              GoRoute(path: path, pageBuilder: (_, __) => page()),
            GoRoute(path: '/antiga', builder: (_, __) => const SizedBox()),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        Future<void> settle() async {
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 1));
        }

        await settle();
        router.go('/aulas/42');
        await settle();
        router.push('/perfil');
        await settle();
        router.push('/aulas/7');
        await settle();
        router.pop();
        await settle();
        router.go('/antiga');
        await settle();

        expect(sink.events.map((e) => e.payload['screen.name']), [
          '/',
          '/aulas/:id',
          '/perfil',
          '/aulas/:id',
          '/perfil',
          '/nova',
        ]);
      });
    }

    testWidgets('with no router, an unnamed page is named by its widget',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [ImmunoOpsNavigatorObserver(() => tracker)],
        home: const Text('home'),
      ));
      navigator.currentState!.push(
          const _Page(child: _Splash()).createRoute(navigator.currentContext!));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1));
      // A MaterialPageRoute with no name says nothing: not a screen.
      navigator.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const Text('x')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(
          sink.events.map((e) => e.payload['screen.name']), ['/', '_Splash']);
    });

    testWidgets('pages become screens; dialogs do not', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [ImmunoOpsNavigatorObserver(() => tracker)],
        initialRoute: 'home',
        routes: {
          'home': (_) => const Text('home'),
          '/aulas/42': (_) => const Text('aula'),
        },
      ));
      now = now.add(const Duration(seconds: 3));
      navigator.currentState!.pushNamed('/aulas/42');
      await tester.pumpAndSettle();
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const Text('dialog'),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 2));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      expect(sink.events.map((e) => e.payload['screen.name']),
          ['home', '/aulas/:id', 'home']);
      expect(sink.events[1].payload['screen.previous_name'], 'home');
      expect(sink.named('ui.screen.duration_ms').map((m) => m.value),
          [3000, 2000]);
      expect(sink.currentScreen, 'home');
      expect(sink.active, contains('navigation'));
    });

    test('background pauses the clock of the current screen', () {
      tracker.enter('home');
      now = now.add(const Duration(seconds: 4));
      tracker.pause();
      now = now.add(const Duration(minutes: 10));
      tracker.resume();
      now = now.add(const Duration(seconds: 1));
      tracker.enter('perfil');
      expect(sink.named('ui.screen.duration_ms').map((m) => m.value),
          [4000, 1000]);
    });
  });

  group('errors', () {
    late FakeSink sink;
    late CrashReporter capture;
    late DateTime now;
    late FlutterExceptionHandler? originalFlutter;
    late ErrorCallback? originalPlatform;

    setUp(() {
      sink = FakeSink()..currentScreen = 'checkout';
      now = DateTime(2026);
      capture = CrashReporter(sink, now: () => now);
      originalFlutter = FlutterError.onError;
      originalPlatform = PlatformDispatcher.instance.onError;
    });

    tearDown(() {
      capture.uninstall();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });

    test('framework errors are recorded and still reach the old handler', () {
      final seen = <FlutterErrorDetails>[];
      FlutterError.onError = seen.add;
      capture.install();
      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
        library: 'widgets library',
      ));
      expect(seen, hasLength(1));
      final log = sink.logs.single;
      expect(log.level, ImmunoOpsLogLevel.error);
      expect(log.message, 'StateError: Bad state: boom');
      expect(log.context['exception.unhandled'], isFalse);
      expect(log.context['flutter.library'], 'widgets library');
      expect(log.context['screen.name'], 'checkout');
      expect(log.context['exception.fingerprint'],
          matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('platform errors chain and keep the old return value', () {
      PlatformDispatcher.instance.onError = (_, __) => true;
      capture.install();
      final handled = PlatformDispatcher.instance.onError!(
          Exception('x'), StackTrace.current);
      expect(handled, isTrue);
      expect(sink.logs.single.context['exception.unhandled'], isTrue);
    });

    test('a failure inside the SDK never stops the old handler', () {
      final seen = <Object>[];
      FlutterError.onError = (d) => seen.add(d.exception);
      PlatformDispatcher.instance.onError = (e, _) {
        seen.add(e);
        return true;
      };
      final broken = CrashReporter(_ThrowingSink())..install();
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('a')));
      final handled = PlatformDispatcher.instance.onError!(
          StateError('b'), StackTrace.current);
      expect(seen, hasLength(2));
      expect(handled, isTrue);
      broken.uninstall();
    });

    test('an error whose toString throws is still recorded', () {
      capture.report(_BadToString(), StackTrace.current,
          unhandled: false, source: 't');
      expect(sink.logs.single.message, startsWith('_BadToString: '));
    });

    test('the same error is reported at most 5 times a minute', () {
      final stack = StackTrace.current;
      for (var i = 0; i < 8; i++) {
        capture.report(StateError('loop'), stack,
            unhandled: false, source: 't');
      }
      expect(sink.logs, hasLength(5));
      now = now.add(const Duration(minutes: 2));
      capture.report(StateError('loop'), stack, unhandled: false, source: 't');
      expect(sink.logs, hasLength(6));
    });

    test('notices when another handler replaces it, and restores on uninstall',
        () {
      final previous = FlutterError.onError;
      capture.install();
      expect(capture.overridden, isFalse);
      FlutterError.onError = (_) {};
      expect(capture.overridden, isTrue);
      FlutterError.onError = previous;
      capture.install();
      capture.uninstall();
      expect(FlutterError.onError, previous);
    });
  });

  group('frames', () {
    test('counts slow and frozen frames per screen', () {
      final sink = FakeSink()..currentScreen = 'feed';
      final frames = FrameMonitor(sink, refreshRate: 60);
      frames
        ..record(buildMs: 5, rasterMs: 8)
        ..record(buildMs: 20, rasterMs: 4)
        ..record(buildMs: 3, rasterMs: 900);
      sink.currentScreen = 'perfil';
      frames.record(buildMs: 1, rasterMs: 1);
      frames.report();

      double value(String name, String screen) => sink
          .named(name)
          .firstWhere((m) => m.tags['screen.name'] == screen)
          .value;
      expect(value('ui.frames.total', 'feed'), 3);
      expect(value('ui.frames.slow', 'feed'), 2);
      expect(value('ui.frames.frozen', 'feed'), 1);
      expect(value('ui.frame.jank_ratio', 'feed'), closeTo(2 / 3, 1e-9));
      expect(value('ui.frame.worst_ms', 'feed'), 900);
      expect(value('ui.frames.slow', 'perfil'), 0);

      sink.metrics.clear();
      frames.report();
      expect(sink.metrics, isEmpty, reason: 'counts start over after a report');
    });
  });

  group('network', () {
    late FakeSink sink;
    late NetworkRecorder recorder;

    setUp(() {
      sink = FakeSink()..currentScreen = 'aulas';
      recorder = NetworkRecorder(
        sink,
        ingestUri: Uri.parse('https://aegis.io/agent/ingest/v1/custom'),
        traceHosts: const ['api.cria.com'],
      );
    });

    Dio dioWith(_Adapter adapter) => Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(ImmunoOpsDioInterceptor.withRecorder(recorder));

    test('a successful request becomes one metric with a template route',
        () async {
      final adapter = _Adapter(200);
      await dioWith(adapter).get<void>('https://api.cria.com/v1/aulas/77?x=1');
      final metric = sink.named('http.client.request.duration_ms').single;
      expect(metric.network, isTrue);
      expect(metric.tags, {
        'http.request.method': 'GET',
        'server.address': 'api.cria.com',
        'url.template': '/v1/aulas/:id',
        'http.response.status_code': '200',
      });
      expect(
          adapter.requests.single.headers['tracestate'], 'immunoops=s:sess-1');
      expect(sink.logs, isEmpty);
      expect(adapter.requests.single.headers['traceparent'],
          matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')));
    });

    test('a 503 adds a warning log; a 404 does not', () async {
      final dio503 = dioWith(_Adapter(503));
      await expectLater(dio503.get<void>('https://api.cria.com/v1/pay'),
          throwsA(isA<DioException>()));
      final dio404 = dioWith(_Adapter(404));
      await expectLater(dio404.get<void>('https://api.cria.com/v1/x'),
          throwsA(isA<DioException>()));
      expect(
          sink
              .named('http.client.request.duration_ms')
              .map((m) => m.tags['http.response.status_code']),
          ['503', '404']);
      expect(sink.logs.single.message, 'HTTP 503 GET api.cria.com/v1/pay');
      expect(sink.logs.single.context['trace_id'], hasLength(32));
      expect(sink.logs.single.context['screen.name'], 'aulas');
    });

    test('timeouts and connection errors are told apart', () async {
      await expectLater(
        dioWith(_Adapter(0, throwType: DioExceptionType.receiveTimeout))
            .get<void>('https://other.com/a'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dioWith(_Adapter(0, throwType: DioExceptionType.connectionError))
            .get<void>('https://other.com/b'),
        throwsA(isA<DioException>()),
      );
      expect(
          sink
              .named('http.client.request.duration_ms')
              .map((m) => m.tags['error.type']),
          ['timeout', 'connection_error']);
      expect(sink.logs, hasLength(2));
    });

    test('no traceparent for hosts the app did not opt in', () async {
      final adapter = _Adapter(200);
      await dioWith(adapter).get<void>('https://api.stripe.com/v1/x');
      expect(
          adapter.requests.single.headers.containsKey('traceparent'), isFalse);
    });

    test('the SDK does not measure its own uploads', () async {
      await dioWith(_Adapter(200))
          .post<void>('https://aegis.io/agent/ingest/v1/custom');
      expect(sink.metrics, isEmpty);
    });

    test('the http client wrapper measures and rethrows', () async {
      final client = ImmunoOpsHttpClient.withRecorder(
        recorder,
        MockClient((request) async {
          if (request.url.path == '/down') throw http.ClientException('down');
          return http.Response('', 201);
        }),
      );
      await client.post(Uri.parse('https://api.cria.com/v1/aulas'));
      await expectLater(client.get(Uri.parse('https://api.cria.com/down')),
          throwsA(isA<http.ClientException>()));
      expect(
          sink
              .named('http.client.request.duration_ms')
              .map((m) => m.tags['error.type']),
          [null, 'connection_error']);
    });
  });
}

class _BadToString {
  @override
  String toString() => throw StateError('no string for you');
}

class _ThrowingSink extends FakeSink {
  @override
  void recordLog(
    ImmunoOpsLogLevel level,
    String message, {
    Map<String, Object?> context = const {},
  }) =>
      throw StateError('sink broke');
}

/// Like go_router's CustomTransitionPage: a Page with a `child` and no name.
class _Page extends Page<void> {
  const _Page({super.key, required this.child});

  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => PageRouteBuilder<void>(
        settings: this,
        pageBuilder: (_, __, ___) => child,
      );
}

class _Wrapper extends StatelessWidget {
  const _Wrapper();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
