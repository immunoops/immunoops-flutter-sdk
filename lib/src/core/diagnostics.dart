import 'package:flutter/foundation.dart';

enum DiagnosticSeverity { info, warning, error }

/// One problem the SDK found about its own setup or delivery. Every code
/// is documented in the package README under "Códigos de diagnóstico".
class ImmunoOpsDiagnostic {
  const ImmunoOpsDiagnostic({
    required this.code,
    required this.severity,
    required this.message,
    this.fix,
  });

  final String code;
  final DiagnosticSeverity severity;
  final String message;
  final String? fix;

  Map<String, Object?> toJson() => {
        'code': code,
        'severity': severity.name,
        'message': message,
        if (fix != null) 'fix': fix,
      };

  @override
  String toString() =>
      '[ImmunoOps] $code ${severity.name}: $message${fix == null ? '' : ' → $fix'}';
}

/// What [ImmunoOps.diagnostics] returns: which captures are live and what
/// is wrong, so the app (or the doctor) can show it.
class ImmunoOpsDiagnostics {
  const ImmunoOpsDiagnostics({
    required this.initialized,
    required this.sdkVersion,
    required this.captures,
    required this.issues,
    required this.queued,
    required this.sent,
    required this.dropped,
  });

  final bool initialized;
  final String sdkVersion;

  /// Capture name → whether it is configured and has seen activity.
  final Map<String, bool> captures;
  final List<ImmunoOpsDiagnostic> issues;
  final int queued;
  final int sent;
  final int dropped;

  bool get healthy =>
      issues.every((issue) => issue.severity != DiagnosticSeverity.error);

  Map<String, Object?> toJson() => {
        'initialized': initialized,
        'sdk_version': sdkVersion,
        'captures': captures,
        'issues': [for (final issue in issues) issue.toJson()],
        'queued': queued,
        'sent': sent,
        'dropped': dropped,
      };
}

/// Collects diagnostics once per code and prints them in debug builds.
class DiagnosticsHub {
  DiagnosticsHub({required this.verbose});

  final bool verbose;
  final _issues = <String, ImmunoOpsDiagnostic>{};

  List<ImmunoOpsDiagnostic> get issues => _issues.values.toList();

  void report(ImmunoOpsDiagnostic diagnostic) {
    final isNew = !_issues.containsKey(diagnostic.code);
    _issues[diagnostic.code] = diagnostic;
    if (isNew && (verbose || kDebugMode)) debugPrint('$diagnostic');
  }

  void clear(String code) => _issues.remove(code);

  void trace(String message) {
    if (verbose) debugPrint('[ImmunoOps] $message');
  }
}

/// The catalogue, so codes and wording stay the same everywhere.
abstract final class Diagnostics {
  static ImmunoOpsDiagnostic keyRejected(int? status) => ImmunoOpsDiagnostic(
        code: 'IMMUNO-E001',
        severity: DiagnosticSeverity.error,
        message: 'A ingestão recusou a chave (HTTP $status). '
            'Nada será enviado até o app reiniciar.',
        fix: 'Copie a chave de novo na tela Instrumentação do console.',
      );

  static ImmunoOpsDiagnostic unreachable(String? detail) => ImmunoOpsDiagnostic(
        code: 'IMMUNO-E002',
        severity: DiagnosticSeverity.warning,
        message: 'Ingestão inacessível ($detail); os dados ficam na fila '
            'e serão reenviados.',
        fix: 'Confira o endpoint e a conexão. Na web, a origem do app '
            'precisa estar em AEGIS_CORS_ORIGINS.',
      );

  static ImmunoOpsDiagnostic batchRejected(int? status, String? detail) =>
      ImmunoOpsDiagnostic(
        code: 'IMMUNO-E003',
        severity: DiagnosticSeverity.error,
        message: 'A ingestão recusou um lote (HTTP $status: $detail); '
            'ele foi descartado.',
        fix: 'Atualize o immunoops_flutter; se persistir, abra um chamado.',
      );

  static const notInitialized = ImmunoOpsDiagnostic(
    code: 'IMMUNO-E004',
    severity: DiagnosticSeverity.error,
    message: 'O SDK foi usado antes de ImmunoOps.init.',
    fix: 'Chame ImmunoOps.init no main(), antes do runApp.',
  );

  static const observerMissing = ImmunoOpsDiagnostic(
    code: 'IMMUNO-W101',
    severity: DiagnosticSeverity.warning,
    message: 'Nenhuma navegação foi vista: telas não estão sendo medidas.',
    fix: 'Adicione ImmunoOps.navigatorObserver aos observers do GoRouter '
        'ou do MaterialApp.',
  );

  static const networkMissing = ImmunoOpsDiagnostic(
    code: 'IMMUNO-W102',
    severity: DiagnosticSeverity.warning,
    message: 'Nenhuma requisição HTTP foi medida.',
    fix: 'Adicione ImmunoOpsDioInterceptor() a cada Dio, ou use '
        'ImmunoOpsHttpClient no lugar do http.Client.',
  );

  static ImmunoOpsDiagnostic pluginUnavailable(String plugin) =>
      ImmunoOpsDiagnostic(
        code: 'IMMUNO-W103',
        severity: DiagnosticSeverity.warning,
        message: 'O plugin $plugin não respondeu nesta plataforma; '
            'esses dados do aparelho ficam de fora.',
        fix: 'Rode flutter clean e reinstale o app (plugin nativo novo '
            'exige rebuild).',
      );

  static const queueFull = ImmunoOpsDiagnostic(
    code: 'IMMUNO-W104',
    severity: DiagnosticSeverity.warning,
    message: 'A fila encheu e os itens mais antigos foram descartados.',
    fix: 'Verifique IMMUNO-E002, ou aumente maxQueueSize / reduza o volume '
        'com sampling.',
  );

  static const handlerReplaced = ImmunoOpsDiagnostic(
    code: 'IMMUNO-W105',
    severity: DiagnosticSeverity.warning,
    message: 'Outro código substituiu FlutterError.onError ou '
        'PlatformDispatcher.onError depois do init: erros não chegam mais.',
    fix: 'Chame ImmunoOps.init depois de configurar outras ferramentas de '
        'erro; o SDK repassa os erros a elas.',
  );

  static const consentPending = ImmunoOpsDiagnostic(
    code: 'IMMUNO-I201',
    severity: DiagnosticSeverity.info,
    message: 'requireConsent está ligado e o consentimento ainda não veio: '
        'nada é coletado.',
    fix: 'Chame ImmunoOps.setConsent(true) depois do aceite do usuário.',
  );
}
