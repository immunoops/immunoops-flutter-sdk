import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immunoops_flutter/src/crash/crash_fingerprint.dart';
import 'package:immunoops_flutter/src/rum/route_template.dart';
import 'package:immunoops_flutter/src/core/telemetry_item.dart';
import 'package:immunoops_flutter/src/core/immunoops_config.dart';
import 'package:immunoops_flutter/src/core/privacy/data_sanitizer.dart';
import 'package:immunoops_flutter/src/core/version.dart';

void main() {
  group('payload contract', () {
    test('matches the fields IngestTelemetryPayload reads', () {
      final payload = buildIngestPayload('cria-app', const [
        MetricItem(
          name: 'http.client.duration_ms',
          value: 12.5,
          type: MetricType.gauge,
          tags: {'http.route': '/v1/aulas/:id'},
          timestampMs: 1000,
        ),
        LogItem(
          level: ImmunoOpsLogLevel.error,
          message: 'StateError: boom',
          context: {'error.unhandled': true},
          timestampMs: 2000,
        ),
        EventItem(
            name: 'aula_comprada', payload: {'valor': 89.9}, timestampMs: 3000),
      ]);
      expect(payload, {
        'app_name': 'cria-app',
        'metrics': [
          {
            'name': 'http.client.duration_ms',
            'value': 12.5,
            'type': 'gauge',
            'tags': {'http.route': '/v1/aulas/:id'},
            'timestamp_ms': 1000,
          },
        ],
        'logs': [
          {
            'level': 'error',
            'message': 'StateError: boom',
            'context': {'error.unhandled': true},
            'timestamp_ms': 2000,
          },
        ],
        'events': [
          {
            'event_name': 'aula_comprada',
            'payload': {'valor': 89.9},
            'timestamp_ms': 3000,
          },
        ],
      });
    });

    test('a kind with no items is left out', () {
      expect(buildIngestPayload('a', const []), {'app_name': 'a'});
    });

    test('stored items come back the same', () {
      const items = <TelemetryItem>[
        MetricItem(
            name: 'm', value: 1, type: MetricType.counter, timestampMs: 1),
        LogItem(level: ImmunoOpsLogLevel.warn, message: 'w', timestampMs: 2),
        EventItem(name: 'e', payload: {'k': 'v'}, timestampMs: 3),
      ];
      for (final item in items) {
        final back = TelemetryItem.fromJson(item.toStoredJson())!;
        expect(back.toJson(), item.toJson());
      }
      expect(TelemetryItem.fromJson({'kind': 'other'}), isNull);
    });

    test('the endpoint gets /v1/custom once', () {
      ImmunoOpsConfig opts(String endpoint) =>
          ImmunoOpsConfig(clientKey: 'k', appName: 'a', endpoint: endpoint);
      const want = 'https://h.io/agent/ingest/v1/custom';
      expect(opts('https://h.io/agent/ingest').ingestUri.toString(), want);
      expect(opts('https://h.io/agent/ingest/').ingestUri.toString(), want);
      expect(opts(want).ingestUri.toString(), want);
    });
  });

  group('sanitizer', () {
    test('masks CPF, valid card numbers, e-mails and bearer tokens', () {
      expect(sanitizeString('cpf 123.456.789-09'), 'cpf ***.***.***-**');
      expect(sanitizeString('cartão 4111 1111 1111 1111'),
          'cartão ****-****-****-****');
      expect(sanitizeString('de ana@cria.com'), 'de [EMAIL]');
      expect(sanitizeString('Bearer abc.def.ghi'), 'Bearer [REDACTED]');
    });

    test('URLs in text lose their query string and fragment', () {
      expect(
        sanitizeString('ClientException: Connection reset, '
            'uri=https://api.cria.com/v1/x?token=abc&signature=s3cr3t'),
        'ClientException: Connection reset, '
        'uri=https://api.cria.com/v1/x?[REDACTED]',
      );
      expect(sanitizeString('ver https://cria.com/a#access_token=xyz agora'),
          'ver https://cria.com/a?[REDACTED] agora');
      expect(
          sanitizeString('https://cria.com/aulas'), 'https://cria.com/aulas');
    });

    test('keeps timestamps and other digit runs that fail Luhn', () {
      expect(sanitizeString('em 1760000000123'), 'em 1760000000123');
      expect(sanitizeString('pedido 1234567890123'), 'pedido 1234567890123');
    });

    test('redacts sensitive keys at any depth', () {
      expect(
        sanitizeValue({
          'senha': '123',
          'userToken': 'x',
          'nested': {'cardNumber': '1', 'ok': 'ana@x.com'},
          'list': [
            {'cpf': '1'},
          ],
        }),
        {
          'senha': redacted,
          'userToken': redacted,
          'nested': {'cardNumber': redacted, 'ok': '[EMAIL]'},
          'list': [
            {'cpf': redacted},
          ],
        },
      );
    });

    test('short fragments only match whole words of the key', () {
      expect(isSensitiveKey('pin'), isTrue);
      expect(isSensitiveKey('user_pin'), isTrue);
      expect(isSensitiveKey('rg'), isTrue);
      expect(isSensitiveKey('authHeader'), isTrue);
      expect(isSensitiveKey('battery_charge'), isFalse);
      expect(isSensitiveKey('shipping'), isFalse);
      expect(isSensitiveKey('author'), isFalse);
      expect(isSensitiveKey('screen'), isFalse);
    });
  });

  group('route names', () {
    test('ids, uuids and tokens become :id; query and fragment go', () {
      expect(normalizePath('/aulas/123'), '/aulas/:id');
      expect(normalizePath('/u/3f2a9c1e-5b7d-4e8a-9c21-7d4e5f6a8b90/x'),
          '/u/:id/x');
      expect(normalizePath('/r/a1b2c3d4e5f6a7b8'), '/r/:id');
      expect(normalizePath('/reset/abcDEF123456ghiJKL7890xyz'), '/reset/:id');
      expect(normalizePath('/busca?q=ana@x.com#top'), '/busca');
      expect(normalizePath('/aulas/:aulaId'), '/aulas/:aulaId');
      expect(normalizePath(''), '/');
    });

    test('settings names keep plain names and template paths', () {
      expect(screenNameFrom('home'), 'home');
      expect(screenNameFrom('/aulas/42'), '/aulas/:id');
      expect(screenNameFrom(null), isNull);
      expect(screenNameFrom('  '), isNull);
    });
  });

  test('jsonSafe turns any value into something jsonEncode accepts', () {
    final safe = jsonSafe({
      'quando': DateTime.utc(2026, 10, 19, 12),
      'nivel': ImmunoOpsLogLevel.warn,
      'nan': double.nan,
      'inf': double.infinity,
      'objeto': Uri.parse('https://cria.com'),
      'lista': {1, 2},
      'aninhado': {
        3: [DateTime.utc(2026)],
      },
    });
    expect(safe, {
      'quando': '2026-10-19T12:00:00.000Z',
      'nivel': 'warn',
      'nan': null,
      'inf': null,
      'objeto': 'https://cria.com',
      'lista': [1, 2],
      'aninhado': {
        '3': ['2026-01-01T00:00:00.000Z'],
      },
    });
    expect(() => jsonEncode(safe), returnsNormally);
  });

  test('fnv1a matches the reference values', () {
    expect(fnv1a(''), '811c9dc5');
    expect(fnv1a('a'), 'e40c292c');
    expect(fnv1a('foobar'), 'bf9cf968');
  });

  test('sdkVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $sdkVersion\n'));
  });
}
