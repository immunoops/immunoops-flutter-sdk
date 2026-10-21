import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/immunoops_flutter.dart';
import 'package:immunoops_flutter/src/core/immunoops_client.dart';
import 'package:immunoops_flutter/src/core/context/app_context.dart';
import 'package:immunoops_flutter/src/exporter/telemetry_store.dart';

const _attributes = {
  'app.version': '1.2.1',
  'app.build': '29',
  'os.name': 'android',
};

void main() {
  late List<Map<String, dynamic>> bodies;
  late MemoryTelemetryStore store;
  late FlutterExceptionHandler? originalFlutter;
  late ErrorCallback? originalPlatform;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 10, 19, 9);
    bodies = [];
    store = MemoryTelemetryStore();
    originalFlutter = FlutterError.onError;
    originalPlatform = PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    FlutterError.onError = originalFlutter;
    PlatformDispatcher.instance.onError = originalPlatform;
  });

  ImmunoOpsClient build({
    ImmunoOpsCaptures captures = const ImmunoOpsCaptures(device: false),
    ImmunoOpsSampling sampling = const ImmunoOpsSampling(),
    bool requireConsent = false,
  }) =>
      ImmunoOpsClient(
        ImmunoOpsConfig(
          clientKey: 'key',
          appName: 'cria-app',
          environment: 'staging',
          captures: captures,
          sampling: sampling,
          requireConsent: requireConsent,
          sessionTimeout: const Duration(minutes: 30),
        ),
        store: store,
        attributes: AppContext(
          appName: 'cria-app',
          environment: 'staging',
          appVersion: _attributes['app.version'],
          appBuild: _attributes['app.build'],
          osName: _attributes['os.name'],
        ),
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
        now: () => now,
      );

  Future<ImmunoOpsClient> started(
    WidgetTester tester, {
    ImmunoOpsCaptures captures = const ImmunoOpsCaptures(device: false),
    ImmunoOpsSampling sampling = const ImmunoOpsSampling(),
    bool requireConsent = false,
  }) async {
    final client = build(
        captures: captures, sampling: sampling, requireConsent: requireConsent);
    client.installSync();
    await client.start();
    return client;
  }

  List<Map<String, dynamic>> sent(String kind) => [
        for (final body in bodies)
          for (final item in (body[kind] as List? ?? const []))
            item as Map<String, dynamic>,
      ];

  testWidgets('items recorded before start wait, then go enriched',
      (tester) async {
    final client = build()..installSync();
    client.recordMetric('early', 1, tags: const {'k': 'v'});
    await client.start();
    client
      ..recordLog(ImmunoOpsLogLevel.info, 'oi', context: const {'a': 1})
      ..recordEvent('aula_comprada', const {'valor': 89.9});
    await client.buffer.flush(force: true);

    final metric = sent('metrics').firstWhere((m) => m['name'] == 'early');
    expect(metric['tags'], containsPair('service.version', '1.2.1'));
    expect(
        metric['tags'], containsPair('deployment.environment.name', 'staging'));
    expect(metric['tags'], containsPair('k', 'v'));
    expect((metric['tags'] as Map).containsKey('session.id'), isFalse,
        reason: 'no high-cardinality ids on metrics');

    final log = sent('logs').single;
    expect(log['context'], containsPair('a', 1));
    expect((log['context'] as Map)['session.id'], isA<String>());
    expect((log['context'] as Map)['app.installation.id'], store.installId);

    final event =
        sent('events').firstWhere((e) => e['event_name'] == 'aula_comprada');
    expect(event['payload'], containsPair('valor', 89.9));
    expect(event['payload'],
        containsPair('telemetry.sdk.name', 'immunoops-flutter'));
    expect(bodies.first['app_name'], 'cria-app');
    await client.shutdown();
  });

  testWidgets('user data is sanitized before it is queued', (tester) async {
    final client = await started(tester);
    client
      ..recordLog(ImmunoOpsLogLevel.info, 'cliente ana@cria.com',
          context: const {'senha': 'x', 'cpf_cliente': '123.456.789-09'})
      ..recordMetric('m', 1, tags: const {'token': 'abc', 'plano': 'premium'});
    await client.buffer.flush(force: true);
    final log = sent('logs').single;
    expect(log['message'], 'cliente [EMAIL]');
    expect(
        log['context'], containsPair('senha', '[REDACTED_BY_IMMUNOOPS_LGPD]'));
    expect(log['context'],
        containsPair('cpf_cliente', '[REDACTED_BY_IMMUNOOPS_LGPD]'));
    final metric = sent('metrics').firstWhere((m) => m['name'] == 'm');
    expect(
        metric['tags'], containsPair('token', '[REDACTED_BY_IMMUNOOPS_LGPD]'));
    expect(metric['tags'], containsPair('plano', 'premium'));
    await client.shutdown();
  });

  testWidgets('values that are not JSON never block the queue', (tester) async {
    final client = await started(tester);
    client
      ..recordEvent('checkout', {'em': DateTime.utc(2026), 'nan': double.nan})
      ..recordLog(ImmunoOpsLogLevel.info, 'x',
          context: {'nivel': ImmunoOpsLogLevel.warn});
    await client.buffer.flush(force: true);
    expect(client.buffer.queued, 0);
    final event =
        sent('events').firstWhere((e) => e['event_name'] == 'checkout');
    expect(event['payload'], containsPair('em', '2026-01-01T00:00:00.000Z'));
    expect(event['payload'], containsPair('nan', null));
    expect(sent('logs').single['context'], containsPair('nivel', 'warn'));
    await client.shutdown();
  });

  testWidgets('with requireConsent nothing is kept until consent',
      (tester) async {
    final client = await started(tester, requireConsent: true);
    client.recordEvent('antes');
    expect(client.report().issues.map((i) => i.code), contains('IMMUNO-I201'));
    await client.setConsent(true);
    client.recordEvent('depois');
    await client.setConsent(false);
    client.recordEvent('negado');
    await client.buffer.flush(force: true);
    expect(sent('events'), isEmpty,
        reason: 'withdrawing consent drops the queue');

    await client.setConsent(true);
    client.recordEvent('de-novo');
    await client.buffer.flush(force: true);
    expect(sent('events').map((e) => e['event_name']), ['de-novo']);
    await client.shutdown();
  });

  testWidgets('sampling drops data but never error logs', (tester) async {
    final client = await started(
      tester,
      sampling: const ImmunoOpsSampling(metrics: 0, logs: 0, events: 0),
    );
    client
      ..recordMetric('m', 1)
      ..recordEvent('e')
      ..recordLog(ImmunoOpsLogLevel.info, 'info')
      ..recordLog(ImmunoOpsLogLevel.error, 'erro');
    await client.buffer.flush(force: true);
    expect(sent('metrics'), isEmpty);
    expect(sent('events'), isEmpty);
    expect(sent('logs').map((l) => l['message']), ['erro']);
    await client.shutdown();
  });

  testWidgets(
      'going to background sends at once; a long absence starts a '
      'new session', (tester) async {
    final client = await started(tester);
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    final events = sent('events').map((e) => e['event_name']).toList();
    expect(events, containsAll(['session_start', 'app_background']));
    final session1 = sent('events')
            .firstWhere((e) => e['event_name'] == 'session_start')['payload']
        ['session.id'];

    now = now.add(const Duration(minutes: 31));
    client.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await client.buffer.flush(force: true);
    final starts =
        sent('events').where((e) => e['event_name'] == 'session_start');
    expect(starts, hasLength(2));
    expect(starts.last['payload']['session.id'], isNot(session1));
    await client.shutdown();
  });

  testWidgets('the self-check names what is missing and sends the handshake',
      (tester) async {
    final client = await started(tester);
    client.selfCheck();
    final codes = client.report().issues.map((i) => i.code);
    expect(codes, containsAll(['IMMUNO-W101', 'IMMUNO-W102']));
    await client.buffer.flush(force: true);
    final handshake = sent('events')
        .firstWhere((e) => e['event_name'] == 'immunoops.sdk_handshake');
    expect(handshake['payload']['captures.active']['errors'], isTrue);
    expect(handshake['payload']['captures.active']['navigation'], isFalse);
    expect(handshake['payload']['issues'], contains('IMMUNO-W101'));
    await client.shutdown();
  });

  testWidgets(
      'device plugins missing on this platform become a diagnostic, '
      'not a crash', (tester) async {
    final client = await started(tester, captures: const ImmunoOpsCaptures());
    await tester.runAsync(() => client.device!.sample());
    expect(client.report().issues.map((i) => i.code), contains('IMMUNO-W103'));
    await client.shutdown();
  });

  testWidgets('the facade routes calls, reports errors and restores handlers',
      (tester) async {
    final before = FlutterError.onError;
    ImmunoOps.metric('ignored', 1); // before init: no throw
    expect(ImmunoOps.diagnostics().initialized, isFalse);

    final client = build();
    await ImmunoOps.init(client.options, client: client);
    await ImmunoOps.ready;
    ImmunoOps.metric('checkout_latency_ms', 420, tags: {'metodo': 'pix'});
    ImmunoOps.increment('aula_reservada');
    ImmunoOps.event('aula_comprada', {'valor': 89.9});
    ImmunoOps.error(
        StateError('falhou'), StackTrace.current, {'tela': 'pagamento'});
    ImmunoOps.setGlobalTag('plano', 'premium');
    await ImmunoOps.time('db_ms', () async => 1);
    await ImmunoOps.flush();

    expect(sent('metrics').map((m) => m['name']),
        containsAll(['checkout_latency_ms', 'aula_reservada', 'db_ms']));
    expect(
        sent('metrics')
            .firstWhere((m) => m['name'] == 'aula_reservada')['type'],
        'counter');
    expect(sent('metrics').firstWhere((m) => m['name'] == 'db_ms')['tags'],
        containsPair('plano', 'premium'));
    final error = sent('logs').single;
    expect(error['message'], 'StateError: Bad state: falhou');
    expect(error['context'], containsPair('tela', 'pagamento'));
    expect(error['context'], containsPair('exception.source', 'manual'));
    expect(ImmunoOps.diagnostics().initialized, isTrue);

    await ImmunoOps.shutdown();
    expect(FlutterError.onError, before);
  });

  testWidgets(
      'init without key or app name leaves the SDK off but still '
      'runs the app', (tester) async {
    var ran = false;
    await ImmunoOps.init(
      const ImmunoOpsConfig(clientKey: '', appName: 'a'),
      appRunner: () => ran = true,
    );
    expect(ran, isTrue);
    expect(ImmunoOps.diagnostics().initialized, isFalse);
  });
}
