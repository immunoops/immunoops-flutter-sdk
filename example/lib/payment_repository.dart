import 'package:dio/dio.dart';

/// What the simulated payment API does on the next call, one per row of
/// the INC-ANDROID-204 timeline (doc/simulation.md).
enum PaymentScenario { success, slow, timeout, gateway504, serverError, crash }

/// The payment API of the sample store. [baseUrl] points at any server
/// that answers `/status/<code>` and `/delay/<seconds>` (httpbin works);
/// the integration test runs its own.
class PaymentRepository {
  PaymentRepository(this._dio, {required this.baseUrl});

  final Dio _dio;
  final String baseUrl;

  Future<String> pay({
    required double amount,
    required PaymentScenario scenario,
  }) async {
    switch (scenario) {
      case PaymentScenario.success:
        await _dio.post<void>('$baseUrl/status/200', data: {'amount': amount});
        return 'pago';
      case PaymentScenario.slow:
        await _dio.post<void>('$baseUrl/delay/2', data: {'amount': amount});
        return 'pago (lento)';
      case PaymentScenario.timeout:
        await _dio.post<void>(
          '$baseUrl/delay/10',
          data: {'amount': amount},
          options: Options(receiveTimeout: const Duration(seconds: 1)),
        );
        return 'inalcançável';
      case PaymentScenario.gateway504:
        await _dio.post<void>('$baseUrl/status/504');
        return 'inalcançável';
      case PaymentScenario.serverError:
        await _dio.post<void>('$baseUrl/status/500');
        return 'inalcançável';
      case PaymentScenario.crash:
        // The NullPointerException of the PDF, in Dart terms.
        final Map<String, Object?> response = {};
        return (response['receipt'] as Map<String, Object?>)['id']! as String;
    }
  }
}
