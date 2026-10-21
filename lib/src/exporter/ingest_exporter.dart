import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How a batch went, decided only by the HTTP outcome.
enum SendOutcome {
  /// Accepted; drop the batch.
  sent,

  /// Network down, timeout, 429 or 5xx; keep the batch and try later.
  retry,

  /// 401/403: the key is wrong or revoked; stop sending until restart.
  unauthorized,

  /// Any other 4xx: this batch will never be accepted; drop it.
  rejected,
}

class SendResult {
  const SendResult(this.outcome, {this.statusCode, this.detail});

  final SendOutcome outcome;
  final int? statusCode;
  final String? detail;
}

/// Posts one JSON batch to the ingest route. Only `Authorization` and
/// `Content-Type` go out: any other header turns a browser request into a
/// CORS preflight the API does not allow.
class IngestExporter {
  IngestExporter({
    required this.uri,
    required this.clientKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final Uri uri;
  final String clientKey;
  final Duration timeout;
  final http.Client _client;

  Future<SendResult> send(Map<String, Object?> payload) async {
    final String body;
    try {
      body = jsonEncode(payload);
    } catch (error) {
      // Retrying cannot fix a batch that does not encode: drop it.
      return SendResult(SendOutcome.rejected, detail: 'JSON inválido: $error');
    }
    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $clientKey',
            },
            body: body,
          )
          .timeout(timeout);
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        return SendResult(SendOutcome.sent, statusCode: code);
      }
      final detail = _short(response.body);
      if (code == 401 || code == 403) {
        return SendResult(SendOutcome.unauthorized,
            statusCode: code, detail: detail);
      }
      if (code == 408 || code == 429 || code >= 500) {
        return SendResult(SendOutcome.retry, statusCode: code, detail: detail);
      }
      return SendResult(SendOutcome.rejected, statusCode: code, detail: detail);
    } on TimeoutException {
      return const SendResult(SendOutcome.retry, detail: 'timeout');
    } catch (error) {
      return SendResult(SendOutcome.retry, detail: _short('$error'));
    }
  }

  void close() => _client.close();

  static String _short(String text) =>
      text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
