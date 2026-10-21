import 'dart:convert';
import 'dart:io';

import 'package:immunoops_flutter/src/doctor/checks.dart';
import 'package:immunoops_flutter/src/doctor/doctor.dart';

const _usage = '''
Uso: dart run immunoops_flutter:doctor [opções]

Verifica a integração do immunoops_flutter no app desta pasta.

  --project <pasta>   raiz do app (padrão: pasta atual)
  --key <chave>       chave da tela Instrumentação (ou IMMUNOOPS_CLIENT_KEY)
  --endpoint <url>    endereço de ingestão que o console mostra
  --origin <url>      origem do app web, para testar o CORS
  --send-test         envia um evento immunoops.doctor_ping para validar a chave
  --json              saída em JSON
  --ci                termina com código 1 se houver erro
  -h, --help          esta ajuda
''';

Future<void> main(List<String> args) async {
  String? value(String flag) {
    final at = args.indexOf(flag);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  if (args.contains('-h') || args.contains('--help')) {
    stdout.write(_usage);
    return;
  }

  final options = DoctorOptions(
    projectDir: Directory(value('--project') ?? Directory.current.path),
    clientKey: value('--key'),
    endpoint: value('--endpoint') ??
        Platform.environment['IMMUNOOPS_ENDPOINT'] ??
        'https://aegis.funccloud.com/agent/ingest',
    webOrigin: value('--origin'),
    sendTest: args.contains('--send-test'),
  );
  final checks = await runDoctor(options);
  final failed = checks.any((c) => c.status == CheckStatus.error);

  if (args.contains('--json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ')
        .convert([for (final c in checks) c.toJson()]));
  } else {
    _print(checks);
  }
  if (args.contains('--ci') && failed) exitCode = 1;
}

void _print(List<DoctorCheck> checks) {
  final color = stdout.supportsAnsiEscapes;
  String paint(String text, int code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;
  final (icon, tone) = (
    {
      CheckStatus.ok: '✓',
      CheckStatus.info: 'i',
      CheckStatus.warning: '!',
      CheckStatus.error: '✗',
    },
    {
      CheckStatus.ok: 32,
      CheckStatus.info: 36,
      CheckStatus.warning: 33,
      CheckStatus.error: 31,
    },
  );

  stdout.writeln('Immuno Ops doctor\n');
  for (final check in checks) {
    stdout.writeln(
      '${paint('[${icon[check.status]}]', tone[check.status]!)} '
      '${check.title} ${paint('(${check.code})', 90)}',
    );
    for (final line in (check.detail ?? '').split('\n')) {
      if (line.isNotEmpty) stdout.writeln('    $line');
    }
    if (check.fix != null && check.status != CheckStatus.ok) {
      stdout.writeln('    ${paint('→ ${check.fix}', 90)}');
    }
  }
  final errors = checks.where((c) => c.status == CheckStatus.error).length;
  final warnings = checks.where((c) => c.status == CheckStatus.warning).length;
  stdout.writeln(
    '\n${errors == 0 && warnings == 0 ? 'Tudo certo.' : '$errors erro(s), $warnings aviso(s).'}',
  );
}
