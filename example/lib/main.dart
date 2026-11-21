import 'package:dio/dio.dart';
import 'package:immunoops_flutter/immunoops_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'checkout_page.dart';
import 'payment_repository.dart';

// flutter run --dart-define=IMMUNOOPS_CLIENT_KEY=<chave> \
//   --dart-define=IMMUNOOPS_ENDPOINT=https://staging.immunoops.io/agent/ingest
const _key = String.fromEnvironment('IMMUNOOPS_CLIENT_KEY');
const _endpoint = String.fromEnvironment(
  'IMMUNOOPS_ENDPOINT',
  defaultValue: ImmunoOpsConfig.defaultEndpoint,
);
const _paymentApi = String.fromEnvironment(
  'PAYMENT_API',
  defaultValue: 'https://httpbin.org',
);

void main() {
  ImmunoOps.init(
    const ImmunoOpsConfig(
      clientKey: _key,
      appName: 'immunoops-flutter-example',
      environment: 'development',
      endpoint: _endpoint,
      traceHosts: ['httpbin.org'],
      debug: true,
    ),
    appRunner: () => runApp(SampleStoreApp(
      payments: PaymentRepository(
        Dio()..interceptors.add(ImmunoOpsDioInterceptor()),
        baseUrl: _paymentApi,
      ),
    )),
  );
}

class SampleStoreApp extends StatelessWidget {
  const SampleStoreApp({super.key, required this.payments});

  final PaymentRepository payments;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Loja exemplo',
        navigatorObservers: [ImmunoOps.navigatorObserver],
        initialRoute: 'home',
        routes: {
          'home': (_) => const HomePage(),
          'checkout': (_) => CheckoutPage(payments: payments),
          'slow': (_) => const SlowPage(),
        },
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _broken = false;

  @override
  Widget build(BuildContext context) {
    final report = ImmunoOps.diagnostics();
    return Scaffold(
      appBar: AppBar(title: const Text('Loja exemplo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_key.isEmpty)
            const Text('Sem IMMUNOOPS_CLIENT_KEY: o SDK está desligado.'),
          FilledButton(
            key: const ValueKey('open-checkout'),
            onPressed: () => Navigator.of(context).pushNamed('checkout'),
            child: const Text('Ir para o checkout'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pushNamed('slow'),
            child: const Text('Tela lenta (renderização)'),
          ),
          OutlinedButton(
            onPressed: () => setState(() => _broken = true),
            child: const Text('Erro de build'),
          ),
          OutlinedButton(
            onPressed: () => Future<void>.delayed(
                Duration.zero, () => throw StateError('falha assíncrona')),
            child: const Text('Erro assíncrono não tratado'),
          ),
          OutlinedButton(
            onPressed: () => WidgetsBinding.instance.handleMemoryPressure(),
            child: const Text('Simular pressão de memória'),
          ),
          OutlinedButton(
            onPressed: () => ImmunoOps.flush(),
            child: const Text('Enviar agora'),
          ),
          if (_broken)
            Builder(builder: (_) => throw StateError('erro no build')),
          const Divider(height: 32),
          Text('Autodiagnóstico',
              style: Theme.of(context).textTheme.titleMedium),
          Text('Fila: ${report.queued} · enviados: ${report.sent} · '
              'descartados: ${report.dropped}'),
          for (final MapEntry(key: name, value: on) in report.captures.entries)
            Text('${on ? '✓' : '·'} $name'),
          for (final issue in report.issues)
            Text('${issue.code}: ${issue.message}'),
          TextButton(
            onPressed: () => setState(() {}),
            child: const Text('Atualizar diagnóstico'),
          ),
        ],
      ),
    );
  }
}

class SlowPage extends StatelessWidget {
  const SlowPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Blocks the UI thread for 400 ms: a frozen frame on purpose.
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 400) {}
    return Scaffold(
      appBar: AppBar(title: const Text('Tela lenta')),
      body: const Center(child: Text('Este build travou 400 ms.')),
    );
  }
}
