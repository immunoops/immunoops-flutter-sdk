import 'package:immunoops_flutter/immunoops_flutter.dart';
import 'package:flutter/material.dart';

import 'payment_repository.dart';

/// The checkout journey of the sample store. Every attempt is one
/// `checkout.payment` journey: its duration and outcome feed the checkout
/// latency and success rate (IMOB-019/020); errors and requests inside it
/// carry its name.
class CheckoutPage extends StatefulWidget {
  const CheckoutPage({super.key, required this.payments});

  final PaymentRepository payments;

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  String _status = 'Escolha um cenário de pagamento.';
  bool _paying = false;

  Future<void> _pay(PaymentScenario scenario) async {
    setState(() {
      _paying = true;
      _status = 'Pagando…';
    });
    final journey = ImmunoOps.startJourney(
      'checkout.payment',
      attributes: {'payment.method': 'pix'},
    );
    try {
      final result =
          await widget.payments.pay(amount: 89.90, scenario: scenario);
      journey.end();
      _show('Pagamento $result.');
    } catch (error, stack) {
      journey.fail(error, stack);
      _show('Falhou: ${error.runtimeType}.');
    }
  }

  void _show(String text) {
    if (!mounted) return;
    setState(() {
      _paying = false;
      _status = text;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final scenario in PaymentScenario.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.tonal(
                  key: ValueKey('pay-${scenario.name}'),
                  onPressed: _paying ? null : () => _pay(scenario),
                  child: Text('Pagar: ${scenario.name}'),
                ),
              ),
            const SizedBox(height: 16),
            Text(_status, key: const ValueKey('checkout-status')),
          ],
        ),
      );
}
