import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/src/core/diagnostics.dart';
import 'package:immunoops_flutter/src/core/telemetry_item.dart';
import 'package:immunoops_flutter/src/exporter/telemetry_buffer.dart';
import 'package:immunoops_flutter/src/exporter/telemetry_store.dart';
import 'package:immunoops_flutter/src/exporter/telemetry_store_io.dart';
import 'package:immunoops_flutter/src/exporter/ingest_exporter.dart';

final _uri = Uri.parse('https://h.io/agent/ingest/v1/custom');

MetricItem _metric(int i) =>
    MetricItem(name: 'm$i', value: i.toDouble(), timestampMs: i);

void main() {
  group('IngestExporter', () {
    Future<SendResult> sendWith(int status) => IngestExporter(
          uri: _uri,
          clientKey: 'key',
          client: MockClient((_) async => http.Response('nope', status)),
        ).send(const {'app_name': 'a'});

    test('status codes map to outcomes', () async {
      expect((await sendWith(200)).outcome, SendOutcome.sent);
      expect((await sendWith(401)).outcome, SendOutcome.unauthorized);
      expect((await sendWith(403)).outcome, SendOutcome.unauthorized);
      expect((await sendWith(429)).outcome, SendOutcome.retry);
      expect((await sendWith(503)).outcome, SendOutcome.retry);
      expect((await sendWith(400)).outcome, SendOutcome.rejected);
      expect((await sendWith(413)).outcome, SendOutcome.rejected);
    });

    test('a network failure is retried', () async {
      final result = await IngestExporter(
        uri: _uri,
        clientKey: 'key',
        client: MockClient((_) async => throw const SocketException('down')),
      ).send(const {});
      expect(result.outcome, SendOutcome.retry);
    });

    test('sends only Authorization and Content-Type, and the JSON body',
        () async {
      late http.Request seen;
      await IngestExporter(
        uri: _uri,
        clientKey: 'key',
        client: MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      ).send(const {'app_name': 'a'});
      expect(seen.method, 'POST');
      expect(seen.url, _uri);
      expect(seen.headers.keys.map((k) => k.toLowerCase()).toSet(),
          {'authorization', 'content-type'});
      expect(seen.headers['Authorization'], 'Bearer key');
      expect(jsonDecode(seen.body), {'app_name': 'a'});
    });
  });

  group('TelemetryBuffer', () {
    late List<Map<String, Object?>> bodies;
    late List<int> statuses;
    late MemoryTelemetryStore store;
    late DiagnosticsHub hub;
    late DateTime now;

    TelemetryBuffer build({int batch = 2, int queue = 10}) {
      bodies = [];
      store = MemoryTelemetryStore();
      hub = DiagnosticsHub(verbose: false);
      now = DateTime(2026, 10, 19, 12);
      return TelemetryBuffer(
        transport: IngestExporter(
          uri: _uri,
          clientKey: 'k',
          client: MockClient((request) async {
            bodies.add(jsonDecode(request.body) as Map<String, Object?>);
            final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
            return http.Response('', status);
          }),
        ),
        store: store,
        appName: 'cria-app',
        diagnostics: hub,
        maxBatchSize: batch,
        maxQueueSize: queue,
        now: () => now,
        random: Random(1),
      );
    }

    setUp(() => statuses = []);

    test('sends in batches and empties the queue', () async {
      final d = build();
      for (var i = 0; i < 5; i++) {
        d.add(_metric(i));
      }
      await d.flush();
      expect(bodies.length, 3);
      expect((bodies.first['metrics'] as List).length, 2);
      expect(bodies.first['app_name'], 'cria-app');
      expect(d.queued, 0);
      expect(d.sent, 5);
    });

    test('a failure keeps the items, writes them to disk and backs off',
        () async {
      final d = build();
      statuses = [503];
      d
        ..add(_metric(1))
        ..add(_metric(2));
      await d.flush();
      expect(d.queued, 2);
      expect(store.queue.length, 2);
      expect(hub.issues.single.code, 'IMMUNO-E002');

      await d.flush();
      expect(bodies.length, 1, reason: 'still inside the back-off window');

      now = now.add(const Duration(seconds: 7));
      await d.flush();
      expect(bodies.length, 2);
      expect(d.queued, 0);
      expect(store.queue, isEmpty, reason: 'the disk copy is cleared');
      expect(hub.issues, isEmpty);
    });

    test('force skips the back-off wait', () async {
      final d = build();
      statuses = [503];
      d.add(_metric(1));
      await d.flush();
      await d.flush(force: true);
      expect(bodies.length, 2);
      expect(d.queued, 0);
    });

    test('a rejected key stops everything and drops the queue', () async {
      final d = build();
      statuses = [401];
      d
        ..add(_metric(1))
        ..add(_metric(2))
        ..add(_metric(3));
      await d.flush();
      expect(d.blocked, isTrue);
      expect(d.queued, 0);
      expect(store.queue, isEmpty);
      expect(hub.issues.single.code, 'IMMUNO-E001');
      d.add(_metric(4));
      expect(d.queued, 0);
    });

    test('a rejected batch is dropped and the rest still goes', () async {
      final d = build();
      statuses = [400];
      for (var i = 0; i < 3; i++) {
        d.add(_metric(i));
      }
      await d.flush();
      expect(bodies.length, 2);
      expect(d.dropped, 2);
      expect(d.sent, 1);
      expect(hub.issues.single.code, 'IMMUNO-E003');
    });

    test('a batch that cannot be encoded is dropped, never retried forever',
        () async {
      final d = build();
      d
        ..add(LogItem(
          level: ImmunoOpsLogLevel.info,
          message: 'raw',
          context: {'quando': DateTime(2026)},
          timestampMs: 0,
        ))
        ..add(_metric(1))
        ..add(_metric(2));
      await d.persist();
      expect(store.queue, hasLength(2), reason: 'the bad item stays off disk');
      await d.flush();
      expect(d.dropped, 2, reason: 'the first batch held the bad item');
      expect(d.sent, 1);
      expect(d.queued, 0);
      expect(hub.issues.single.code, 'IMMUNO-E003');
    });

    test('a full queue drops the oldest items', () async {
      final d = build(batch: 100, queue: 3);
      for (var i = 0; i < 5; i++) {
        d.add(_metric(i));
      }
      expect(d.queued, 3);
      expect(d.dropped, 2);
      expect(hub.issues.single.code, 'IMMUNO-W104');
      await d.flush();
      expect((bodies.single['metrics'] as List).map((m) => (m as Map)['name']),
          ['m2', 'm3', 'm4']);
    });

    test('items left on disk by a previous run go first', () async {
      final d = build();
      store.queue = [_metric(0).toStoredJson()];
      d.add(_metric(1));
      await d.start(autoFlush: false);
      await d.flush();
      expect((bodies.single['metrics'] as List).map((m) => (m as Map)['name']),
          ['m0', 'm1']);
    });

    test('the batch in flight survives a trim and a clear', () async {
      final gate = Completer<void>();
      final store = MemoryTelemetryStore();
      final sent = <Map<String, Object?>>[];
      final d = TelemetryBuffer(
        transport: IngestExporter(
          uri: _uri,
          clientKey: 'k',
          client: MockClient((request) async {
            sent.add(jsonDecode(request.body) as Map<String, Object?>);
            await gate.future;
            return http.Response('', 200);
          }),
        ),
        store: store,
        appName: 'a',
        diagnostics: DiagnosticsHub(verbose: false),
        maxBatchSize: 2,
        maxQueueSize: 3,
      );
      d
        ..add(_metric(0))
        ..add(_metric(1));
      final flushing = d.flush();
      await Future<void>.delayed(Duration.zero);
      d
        ..add(_metric(2))
        ..add(_metric(3));
      expect(d.queued, 3, reason: 'm2 went, the in-flight m0 and m1 stayed');
      await d.clear();
      gate.complete();
      await flushing;
      expect(d.queued, 0);
      expect(d.sent, 0,
          reason: 'a send that returns after clear changes nothing');
    });
  });

  group('FileTelemetryStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('immunoops'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('keeps the queue and the install id across instances', () async {
      FileTelemetryStore store() =>
          FileTelemetryStore(baseDir: () async => dir);
      await store().saveQueue([
        {'kind': 'metric', 'name': 'm'},
      ]);
      await store().writeInstallId('abc');
      expect(await store().loadQueue(), [
        {'kind': 'metric', 'name': 'm'},
      ]);
      expect(await store().readInstallId(), 'abc');
      await store().saveQueue([]);
      expect(File('${dir.path}/immunoops/queue.json').existsSync(), isFalse);
    });

    test('a corrupt queue file is dropped, not thrown', () async {
      Directory('${dir.path}/immunoops').createSync();
      File('${dir.path}/immunoops/queue.json').writeAsStringSync('{oops');
      expect(
        await FileTelemetryStore(baseDir: () async => dir).loadQueue(),
        isEmpty,
      );
    });
  });
}
