// Cost of the SDK on the UI thread (IMOB-024): what one call of each
// public method and each frame callback takes, end to end up to the queue.
// Network and disk run off this path and are not measured here.
//
//   flutter test benchmark/
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/immunoops_flutter.dart';
import 'package:immunoops_flutter/src/core/context/app_context.dart';
import 'package:immunoops_flutter/src/core/immunoops_client.dart';
import 'package:immunoops_flutter/src/exporter/telemetry_store.dart';

const _runs = 20000;

double _microsPerCall(void Function(int i) action) {
  for (var i = 0; i < 2000; i++) {
    action(i);
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < _runs; i++) {
    action(i);
  }
  return watch.elapsedMicroseconds / _runs;
}

void main() {
  testWidgets('cost per call stays far below a frame (16 ms)', (tester) async {
    final client = ImmunoOpsClient(
      const ImmunoOpsConfig(
        clientKey: 'k',
        appName: 'bench',
        maxQueueSize: 1000000,
        maxBatchSize: 1000000,
        captures: ImmunoOpsCaptures(device: false),
      ),
      store: MemoryTelemetryStore(),
      attributes: AppContext(appName: 'bench', environment: 'test'),
      httpClient: MockClient((_) async => http.Response('', 200)),
    )..installSync();
    await client.start();

    final results = {
      'metric': _microsPerCall((i) =>
          client.recordMetric('checkout_ms', i.toDouble(), tags: {'m': 'pix'})),
      'event (sanitized payload)': _microsPerCall((i) => client.recordEvent(
          'aula_comprada', {'valor': 89.9, 'email': 'ana@cria.com', 'n': i})),
      'log': _microsPerCall((i) => client
          .recordLog(ImmunoOpsLogLevel.info, 'sync $i', context: {'k': i})),
      'error with stack': _microsPerCall((i) => client.crash.report(
          StateError('e$i'), StackTrace.current,
          unhandled: false, source: 'bench')),
      'frame timing': _microsPerCall(
          (i) => client.frames.record(buildMs: 4, rasterMs: i % 20.0)),
      'journey start+end': _microsPerCall(
          (i) => client.journeys.start('checkout.payment').end()),
    };

    // ignore: avoid_print
    print([
      'Custo por chamada (µs, média de $_runs):',
      for (final MapEntry(key: name, value: micros) in results.entries)
        '  ${name.padRight(28)} ${micros.toStringAsFixed(2)}',
    ].join('\n'));
    for (final micros in results.values) {
      expect(micros, lessThan(500), reason: 'one call must cost < 0.5 ms');
    }
    await client.shutdown();
  });
}
