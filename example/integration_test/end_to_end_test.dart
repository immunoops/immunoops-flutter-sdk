import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immunoops_flutter/immunoops_flutter.dart';
import 'package:immunoops_flutter_example/main.dart';
import 'package:immunoops_flutter_example/payment_repository.dart';
import 'package:integration_test/integration_test.dart';

// The INC-ANDROID-204 checkout incident (doc/simulation.md) on a real
// platform, against a local server that plays both the payment API and
// the Immuno Ops ingest route:
//   flutter test integration_test -d <device>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('checkout incident: version, session, trace and journey line up',
      (tester) async {
    final bodies = <Map<String, dynamic>>[];
    final paymentHeaders = <Map<String, String?>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.pathSegments;
      final text = await utf8.decoder.bind(request).join();
      if (request.uri.path == '/agent/ingest/v1/custom') {
        bodies.add(jsonDecode(text) as Map<String, dynamic>);
      } else {
        paymentHeaders.add({
          'traceparent': request.headers.value('traceparent'),
          'tracestate': request.headers.value('tracestate'),
        });
        if (path.first == 'delay') {
          await Future<void>.delayed(Duration(seconds: int.parse(path.last)));
        }
        if (path.first == 'status') {
          request.response.statusCode = int.parse(path.last);
        }
      }
      try {
        await request.response.close();
      } catch (_) {
        // The client gave up first (the timeout scenario).
      }
    });
    final base = 'http://127.0.0.1:${server.port}';

    await ImmunoOps.init(ImmunoOpsConfig(
      clientKey: 'e2e-key',
      appName: 'loja-exemplo',
      environment: 'test',
      endpoint: '$base/agent/ingest',
      flushInterval: const Duration(hours: 1),
      traceHosts: const ['127.0.0.1'],
    ));
    await ImmunoOps.ready;

    await tester.pumpWidget(SampleStoreApp(
      payments: PaymentRepository(
        Dio()..interceptors.add(ImmunoOpsDioInterceptor()),
        baseUrl: base,
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open-checkout')));
    await tester.pumpAndSettle();

    for (final scenario in [
      PaymentScenario.success,
      PaymentScenario.timeout,
      PaymentScenario.gateway504,
      PaymentScenario.crash,
    ]) {
      await tester.tap(find.byKey(ValueKey('pay-${scenario.name}')));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1500)));
      await tester.pumpAndSettle();
    }
    tester.binding.handleMemoryPressure();
    await tester.pump(const Duration(seconds: 1));
    await ImmunoOps.flush();

    List<Map<String, dynamic>> all(String kind) => [
          for (final body in bodies)
            for (final item in (body[kind] as List? ?? const []))
              item as Map<String, dynamic>,
        ];
    Map<String, dynamic> attrs(Map<String, dynamic> item) =>
        (item['tags'] ?? item['context'] ?? item['payload'])
            as Map<String, dynamic>;

    // Journeys: checkout latency and success rate (IMOB-019/020).
    final journeys = all('metrics')
        .where((m) => m['name'] == 'journey.duration_ms')
        .map((m) => attrs(m)['journey.outcome'])
        .toList();
    expect(journeys, ['success', 'failure', 'failure', 'failure']);

    // Network errors of the timeline, inside the journey, with a trace.
    final networkErrors = all('logs')
        .where((l) => attrs(l)['event.type'] == 'mobile.network.error')
        .toList();
    expect(networkErrors.map((l) => attrs(l)['error.type']),
        containsAll(['timeout', '504']));
    for (final log in networkErrors) {
      expect(attrs(log)['journey.name'], 'checkout.payment');
      expect(attrs(log)['url.template'], startsWith('/'));
      expect(attrs(log)['trace_id'], hasLength(32));
    }

    // The crash during checkout fails the journey with the exception.
    final failures = all('logs')
        .where((l) => attrs(l)['event.type'] == 'mobile.journey.failure')
        .toList();
    expect(failures, hasLength(3));
    expect(failures.last['level'], 'error');
    expect(attrs(failures.last)['exception.stacktrace'], isNotEmpty);

    // One session ties the app to the backend: tracestate carries it.
    final sessionId = attrs(networkErrors.first)['session.id'] as String;
    expect(paymentHeaders, isNotEmpty);
    for (final headers in paymentHeaders) {
      expect(headers['traceparent'], matches(RegExp(r'^00-[0-9a-f]{32}-')));
      expect(headers['tracestate'], 'immunoops=s:$sessionId');
    }

    // Version and platform on every metric.
    for (final metric in all('metrics')) {
      expect(attrs(metric)['service.version'], isNotEmpty);
      expect(attrs(metric)['os.version'], isNotEmpty);
    }

    // Memory pressure and screens.
    expect(all('events').map((e) => e['event_name']),
        containsAll(['session_start', 'screen_view', 'memory_pressure']));
    expect(
        all('events')
            .where((e) => e['event_name'] == 'screen_view')
            .map((e) => attrs(e)['screen.name']),
        containsAll(['home', 'checkout']));

    final report = ImmunoOps.diagnostics();
    expect(report.issues.where((i) => i.code == 'IMMUNO-W103'), isEmpty,
        reason: 'every device plugin answered on this platform');

    await ImmunoOps.shutdown();
    await server.close(force: true);
  });
}
