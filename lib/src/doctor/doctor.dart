import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'checks.dart';

/// What the doctor needs to know; everything but [projectDir] is optional.
class DoctorOptions {
  const DoctorOptions({
    required this.projectDir,
    this.clientKey,
    this.endpoint = 'https://aegis.funccloud.com/agent/ingest',
    this.webOrigin,
    this.sendTest = false,
    this.dartVersion,
    this.httpClient,
  });

  final Directory projectDir;
  final String? clientKey;
  final String endpoint;

  /// The web app's origin (`https://app.exemplo.com`), for the CORS check.
  final String? webOrigin;

  /// Sends one `immunoops.doctor_ping` event to prove the key works.
  final bool sendTest;

  /// Overrides the running Dart version (tests).
  final String? dartVersion;
  final http.Client? httpClient;

  Uri get ingestUri {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    return Uri.parse(base.endsWith('/v1/custom') ? base : '$base/v1/custom');
  }
}

/// Runs every check against an app project and returns them in order.
Future<List<DoctorCheck>> runDoctor(DoctorOptions options) async {
  final project = _Project(options.projectDir);
  final checks = <DoctorCheck>[
    ..._checkPubspec(project, options),
    ..._checkCode(project),
    ..._checkPlatforms(project, options),
    ..._checkRelease(project),
  ];
  checks.addAll(await _checkConnection(project, options));
  return checks;
}

// ------------------------------------------------------------- project

class _Project {
  _Project(this.dir);

  final Directory dir;
  List<_Source>? _sources;

  File file(String relative) => File('${dir.path}/$relative');

  String? read(String relative) {
    final f = file(relative);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  bool exists(String relative) =>
      FileSystemEntity.typeSync('${dir.path}/$relative') !=
      FileSystemEntityType.notFound;

  /// Every Dart file under lib/, read once.
  List<_Source> get sources => _sources ??= () {
        final lib = Directory('${dir.path}/lib');
        if (!lib.existsSync()) return <_Source>[];
        return lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where((f) => !f.path.endsWith('.g.dart'))
            .where((f) => !f.path.endsWith('.freezed.dart'))
            .map((f) => _Source(
                  f.path.substring(dir.path.length + 1),
                  _stripComments(f.readAsStringSync()),
                ))
            .toList();
      }();

  static String _stripComments(String code) => code
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
}

class _Source {
  const _Source(this.path, this.code);

  final String path;
  final String code;
}

// ------------------------------------------------------------- pubspec

List<DoctorCheck> _checkPubspec(_Project project, DoctorOptions options) {
  final checks = <DoctorCheck>[];
  final raw = project.read('pubspec.yaml');
  if (raw == null) {
    return const [
      DoctorCheck(
        code: 'D001',
        title: 'pubspec.yaml',
        status: CheckStatus.error,
        detail: 'Nenhum pubspec.yaml nesta pasta.',
        fix: 'Rode o doctor na raiz do app (ou use --project <pasta>).',
      ),
    ];
  }
  final pubspec = loadYaml(raw);
  final deps = pubspec is YamlMap && pubspec['dependencies'] is YamlMap
      ? pubspec['dependencies'] as YamlMap
      : YamlMap();
  checks.add(deps.containsKey('immunoops_flutter')
      ? const DoctorCheck(
          code: 'D001',
          title: 'Dependência immunoops_flutter',
          status: CheckStatus.ok,
        )
      : const DoctorCheck(
          code: 'D001',
          title: 'Dependência immunoops_flutter',
          status: CheckStatus.error,
          detail: 'immunoops_flutter não está em dependencies.',
          fix: 'Adicione immunoops_flutter ao pubspec.yaml e rode '
              'flutter pub get.',
        ));

  final dart = _dartVersion(options);
  if (dart != null) {
    checks.add(dart >= Version.parse(minDartVersion)
        ? DoctorCheck(
            code: 'D002',
            title: 'Versão do Dart',
            status: CheckStatus.ok,
            detail: '$dart',
          )
        : DoctorCheck(
            code: 'D002',
            title: 'Versão do Dart',
            status: CheckStatus.error,
            detail: '$dart; o SDK exige $minDartVersion ou mais.',
            fix: 'Atualize o Flutter (flutter upgrade).',
          ));
  }

  final conflicts = <String>[];
  for (final MapEntry(key: name, value: ours) in sdkDependencyRanges.entries) {
    final theirs = deps[name];
    if (theirs is! String) continue;
    try {
      final intersection = VersionConstraint.parse(theirs)
          .intersect(VersionConstraint.parse(ours));
      if (intersection.isEmpty) {
        conflicts.add('$name: o app pede $theirs, o SDK aceita $ours');
      }
    } on FormatException {
      continue;
    }
  }
  checks.add(conflicts.isEmpty
      ? const DoctorCheck(
          code: 'D003',
          title: 'Conflitos de versão',
          status: CheckStatus.ok,
        )
      : DoctorCheck(
          code: 'D003',
          title: 'Conflitos de versão',
          status: CheckStatus.error,
          detail: conflicts.join('\n'),
          fix: 'Ajuste a versão no pubspec.yaml do app para caber na faixa '
              'do SDK.',
        ));

  final lock = project.read('pubspec.lock');
  if (lock == null) {
    checks.add(const DoctorCheck(
      code: 'D004',
      title: 'Dependências resolvidas',
      status: CheckStatus.warning,
      detail: 'Sem pubspec.lock.',
      fix: 'Rode flutter pub get.',
    ));
  } else if (deps.containsKey('immunoops_flutter') &&
      !lock.contains('immunoops_flutter')) {
    checks.add(const DoctorCheck(
      code: 'D004',
      title: 'Dependências resolvidas',
      status: CheckStatus.error,
      detail: 'O pubspec.lock não tem immunoops_flutter: a resolução falhou.',
      fix: 'Rode flutter pub get e leia o conflito que ele mostra.',
    ));
  }
  return checks;
}

Version? _dartVersion(DoctorOptions options) {
  final raw = options.dartVersion ?? Platform.version.split(' ').first;
  try {
    return Version.parse(raw);
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------------- code

final _dioCtor = RegExp(r'\bDio\s*\(');
final _httpTopLevel =
    RegExp(r'\bhttp\.(get|post|put|patch|delete|head|read)\s*\(');
final _httpClient = RegExp(r'\bhttp\.Client\s*\(');
final _flutterOnError = RegExp(r'FlutterError\.onError\s*=');
final _platformOnError = RegExp(r'PlatformDispatcher\.instance\.onError\s*=');

List<DoctorCheck> _checkCode(_Project project) {
  final sources = project.sources;
  final checks = <DoctorCheck>[];

  final init =
      sources.where((s) => s.code.contains('ImmunoOps.init(')).toList();
  if (init.isEmpty) {
    checks.add(const DoctorCheck(
      code: 'D010',
      title: 'ImmunoOps.init',
      status: CheckStatus.error,
      detail: 'Nenhuma chamada a ImmunoOps.init em lib/.',
      fix: 'No main(): ImmunoOps.init(ImmunoOpsConfig(...), '
          'appRunner: () => runApp(App())).',
    ));
  } else {
    final file = init.first;
    final initAt = file.code.indexOf('ImmunoOps.init(');
    final runAppAt = file.code.indexOf('runApp(');
    final late =
        runAppAt >= 0 && runAppAt < initAt && !file.code.contains('appRunner');
    checks.add(late
        ? DoctorCheck(
            code: 'D010',
            title: 'ImmunoOps.init',
            status: CheckStatus.warning,
            detail: '${file.path}: runApp aparece antes do init; erros da '
                'abertura e o tempo de abertura ficam de fora.',
            fix: 'Chame ImmunoOps.init antes do runApp, ou passe o runApp '
                'em appRunner.',
          )
        : DoctorCheck(
            code: 'D010',
            title: 'ImmunoOps.init',
            status: CheckStatus.ok,
            detail: file.path,
          ));
  }

  final observers = sources
      .where((s) => s.code.contains('ImmunoOps.navigatorObserver'))
      .toList();
  final shells = sources
      .where((s) => RegExp(r'\b(Stateful)?ShellRoute(\.indexedStack)?\s*\(')
          .hasMatch(s.code))
      .toList();
  if (observers.isEmpty) {
    checks.add(const DoctorCheck(
      code: 'D011',
      title: 'Telas (navigatorObserver)',
      status: CheckStatus.warning,
      detail: 'ImmunoOps.navigatorObserver não aparece em lib/: telas e jank '
          'por tela não serão medidos.',
      fix: 'GoRouter(observers: [ImmunoOps.navigatorObserver], ...) ou '
          'MaterialApp(navigatorObservers: [ImmunoOps.navigatorObserver]).',
    ));
  } else {
    final uses = observers
        .map((s) => 'ImmunoOps.navigatorObserver'.allMatches(s.code).length)
        .fold<int>(0, (a, b) => a + b);
    checks.add(shells.isNotEmpty && uses < 2
        ? DoctorCheck(
            code: 'D011',
            title: 'Telas (navigatorObserver)',
            status: CheckStatus.warning,
            detail: 'O app usa ShellRoute (${shells.first.path}) e o '
                'observer aparece uma vez só: telas dentro do shell não '
                'são vistas.',
            fix: 'Passe observers: [ImmunoOps.navigatorObserver] também em '
                'cada ShellRoute.',
          )
        : DoctorCheck(
            code: 'D011',
            title: 'Telas (navigatorObserver)',
            status: CheckStatus.ok,
            detail: observers.map((s) => s.path).join(', '),
          ));
  }

  final dios = sources.where((s) => _dioCtor.hasMatch(s.code)).toList();
  final missing = dios
      .where((s) => !s.code.contains('ImmunoOpsDioInterceptor'))
      .map((s) => s.path)
      .toList();
  if (dios.isNotEmpty) {
    checks.add(missing.isEmpty
        ? DoctorCheck(
            code: 'D012',
            title: 'Rede (Dio)',
            status: CheckStatus.ok,
            detail: '${dios.length} Dio com interceptor',
          )
        : DoctorCheck(
            code: 'D012',
            title: 'Rede (Dio)',
            status: CheckStatus.warning,
            detail: 'Dio sem ImmunoOpsDioInterceptor:\n${missing.join('\n')}',
            fix: 'dio.interceptors.add(ImmunoOpsDioInterceptor()) em cada um.',
          ));
  }

  final rawHttp = sources
      .where((s) =>
          (_httpTopLevel.hasMatch(s.code) || _httpClient.hasMatch(s.code)) &&
          !s.code.contains('ImmunoOpsHttpClient'))
      .map((s) => s.path)
      .toList();
  if (rawHttp.isNotEmpty) {
    checks.add(DoctorCheck(
      code: 'D013',
      title: 'Rede (pacote http)',
      status: CheckStatus.info,
      detail: 'Chamadas do pacote http não medidas:\n${rawHttp.join('\n')}',
      fix: 'Use ImmunoOpsHttpClient() no lugar de http.Client().',
    ));
  }

  final handlers = sources
      .where((s) =>
          _flutterOnError.hasMatch(s.code) || _platformOnError.hasMatch(s.code))
      .map((s) => s.path)
      .toList();
  if (handlers.isNotEmpty) {
    checks.add(DoctorCheck(
      code: 'D014',
      title: 'Outros handlers de erro',
      status: CheckStatus.warning,
      detail: 'O app também define handlers globais de erro:\n'
          '${handlers.join('\n')}',
      fix: 'Configure-os antes do ImmunoOps.init: o SDK os mantém e repassa '
          'cada erro. Definidos depois, eles desligam a captura.',
    ));
  }
  return checks;
}

// ----------------------------------------------------------- platforms

List<DoctorCheck> _checkPlatforms(_Project project, DoctorOptions options) {
  final checks = <DoctorCheck>[];

  final manifest = project.read('android/app/src/main/AndroidManifest.xml');
  if (manifest != null) {
    checks.add(manifest.contains('android.permission.INTERNET')
        ? const DoctorCheck(
            code: 'D020',
            title: 'Android: permissão de internet',
            status: CheckStatus.ok,
          )
        : const DoctorCheck(
            code: 'D020',
            title: 'Android: permissão de internet',
            status: CheckStatus.error,
            detail: 'O manifesto principal não declara INTERNET: o build de '
                'release não envia nada (debug e profile têm a permissão '
                'por conta própria, então o erro só aparece em produção).',
            fix: 'Em android/app/src/main/AndroidManifest.xml: '
                '<uses-permission android:name="android.permission.INTERNET"/>',
          ));
    final gradle = project.read('android/app/build.gradle.kts') ??
        project.read('android/app/build.gradle') ??
        '';
    final minSdk =
        RegExp(r'minSdk(?:Version)?\s*=?\s*(\d+)').firstMatch(gradle)?.group(1);
    if (minSdk != null && int.parse(minSdk) < 21) {
      checks.add(DoctorCheck(
        code: 'D021',
        title: 'Android: minSdk',
        status: CheckStatus.warning,
        detail: 'minSdk $minSdk; os plugins do SDK pedem 21 ou mais.',
        fix: 'minSdk = 21 em android/app/build.gradle(.kts).',
      ));
    }
  }

  if (project.exists('ios')) {
    final privacy = project.read('ios/Runner/PrivacyInfo.xcprivacy');
    checks.add(privacy != null &&
            privacy.contains('NSPrivacyCollectedDataTypeCrashData') &&
            privacy.contains('NSPrivacyCollectedDataTypePerformanceData')
        ? const DoctorCheck(
            code: 'D022',
            title: 'iOS: dados coletados declarados',
            status: CheckStatus.ok,
          )
        : const DoctorCheck(
            code: 'D022',
            title: 'iOS: dados coletados declarados',
            status: CheckStatus.info,
            detail: 'O SDK coleta dados de crash e de desempenho, que a Apple '
                'pede declarados no manifesto de privacidade e nos dados de '
                'privacidade da App Store.',
            fix: 'Declare NSPrivacyCollectedDataTypeCrashData e '
                'NSPrivacyCollectedDataTypePerformanceData em '
                'ios/Runner/PrivacyInfo.xcprivacy, sem vínculo ao usuário e '
                'sem rastreamento.',
          ));
  }

  if (project.exists('web')) {
    checks.add(options.webOrigin == null
        ? const DoctorCheck(
            code: 'D023',
            title: 'Web: CORS da ingestão',
            status: CheckStatus.info,
            detail: 'O app tem build web: o navegador só envia se a origem do '
                'app estiver liberada na API.',
            fix: 'Rode com --origin https://seu-app para testar; a '
                'liberação é AEGIS_CORS_ORIGINS no deploy da API.',
          )
        : const DoctorCheck(
            code: 'D023',
            title: 'Web: CORS da ingestão',
            status: CheckStatus.info,
            detail: 'Testado na etapa de conexão abaixo.',
          ));
  }
  return checks;
}

// ------------------------------------------------------------- release

List<DoctorCheck> _checkRelease(_Project project) {
  final buildFiles = <String>[
    'Dockerfile',
    'codemagic.yaml',
    'cloudbuild.yaml',
    'cloudbuild-staging.yaml',
    'deploy.sh',
  ].where(project.exists).toList();
  for (final dir in ['fastlane', '.github/workflows', 'scripts', 'tool']) {
    final d = Directory('${project.dir.path}/$dir');
    if (!d.existsSync()) continue;
    buildFiles.addAll(d
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(project.dir.path.length + 1)));
  }
  final obfuscated = buildFiles
      .where((path) => (project.read(path) ?? '').contains('--obfuscate'))
      .toList();
  if (obfuscated.isEmpty) return const [];
  return [
    DoctorCheck(
      code: 'D030',
      title: 'Build ofuscado',
      status: CheckStatus.warning,
      detail: 'Builds com --obfuscate em ${obfuscated.join(', ')}: os stack '
          'traces chegam ofuscados.',
      fix: 'Guarde a pasta de --split-debug-info de cada versão publicada; '
          'sem ela os erros não podem ser lidos depois.',
    ),
  ];
}

// ---------------------------------------------------------- connection

Future<List<DoctorCheck>> _checkConnection(
  _Project project,
  DoctorOptions options,
) async {
  final key = options.clientKey ?? Platform.environment['IMMUNOOPS_CLIENT_KEY'];
  final origin = options.webOrigin;
  final checks = <DoctorCheck>[];
  final client = options.httpClient ?? http.Client();
  try {
    final uri = options.ingestUri;
    if (key == null || key.isEmpty) {
      checks.add(const DoctorCheck(
        code: 'D040',
        title: 'Chave e conexão',
        status: CheckStatus.info,
        detail: 'Sem chave: conexão não testada.',
        fix: 'Rode com --key <chave da tela Instrumentação> (ou '
            'IMMUNOOPS_CLIENT_KEY) e --send-test.',
      ));
    } else {
      checks.add(_checkKeyShape(key));
      checks.add(options.sendTest
          ? await _sendPing(client, uri, key)
          : await _reach(client, uri));
    }
    if (origin != null) checks.add(await _preflight(client, uri, origin));
  } finally {
    if (options.httpClient == null) client.close();
  }
  return checks;
}

DoctorCheck _checkKeyShape(String key) {
  final parts = key.split('.');
  if (parts.length == 2) {
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts.first))),
      );
      if (claims is Map) {
        final name = claims['cluster_name'];
        return DoctorCheck(
          code: 'D041',
          title: 'Formato da chave',
          status: CheckStatus.ok,
          detail: name == null ? null : 'Conexão "$name"',
        );
      }
    } catch (_) {
      // Falls through to the warning.
    }
  }
  return const DoctorCheck(
    code: 'D041',
    title: 'Formato da chave',
    status: CheckStatus.warning,
    detail: 'A chave não tem o formato emitido pelo console.',
    fix: 'Copie a chave inteira na tela Instrumentação.',
  );
}

Future<DoctorCheck> _reach(http.Client client, Uri uri) async {
  try {
    final response = await client.get(uri).timeout(const Duration(seconds: 10));
    return DoctorCheck(
      code: 'D042',
      title: 'Endpoint alcançável',
      status: CheckStatus.ok,
      detail: '$uri (HTTP ${response.statusCode}); use --send-test para '
          'validar a chave.',
    );
  } catch (error) {
    return DoctorCheck(
      code: 'D042',
      title: 'Endpoint alcançável',
      status: CheckStatus.error,
      detail: '$uri: $error',
      fix: 'Confira --endpoint (o endereço que o console mostra) e a rede.',
    );
  }
}

Future<DoctorCheck> _sendPing(http.Client client, Uri uri, String key) async {
  try {
    final response = await client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'events': [
              {
                'event_name': 'immunoops.doctor_ping',
                'payload': {'source': 'doctor'},
                'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 15));
    final code = response.statusCode;
    if (code >= 200 && code < 300) {
      return const DoctorCheck(
        code: 'D043',
        title: 'Envio de teste',
        status: CheckStatus.ok,
        detail: 'A ingestão aceitou a chave; o evento immunoops.doctor_ping '
            'aparece em Ver telemetria.',
      );
    }
    return DoctorCheck(
      code: 'D043',
      title: 'Envio de teste',
      status: CheckStatus.error,
      detail: 'HTTP $code: ${response.body.trim()}',
      fix: code == 401 || code == 403
          ? 'Chave recusada: copie de novo na tela Instrumentação.'
          : 'Confira o endpoint e tente de novo.',
    );
  } catch (error) {
    return DoctorCheck(
      code: 'D043',
      title: 'Envio de teste',
      status: CheckStatus.error,
      detail: '$uri: $error',
      fix: 'Confira --endpoint e a rede.',
    );
  }
}

Future<DoctorCheck> _preflight(
    http.Client client, Uri uri, String origin) async {
  try {
    final request = http.Request('OPTIONS', uri)
      ..headers.addAll({
        'Origin': origin,
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'authorization,content-type',
      });
    final response =
        await client.send(request).timeout(const Duration(seconds: 10));
    final allowed = response.headers['access-control-allow-origin'];
    final status = response.statusCode;
    if (allowed != null && (status < 200 || status >= 300)) {
      return DoctorCheck(
        code: 'D044',
        title: 'Web: CORS da ingestão',
        status: CheckStatus.error,
        detail: 'A origem está liberada, mas o preflight (OPTIONS) responde '
            'HTTP $status; o navegador exige 2xx e bloqueia o envio.',
        fix: 'Correção no backend: a rota de ingestão precisa responder 204 '
            'a OPTIONS.',
      );
    }
    return allowed == origin || allowed == '*'
        ? DoctorCheck(
            code: 'D044',
            title: 'Web: CORS da ingestão',
            status: CheckStatus.ok,
            detail: '$origin liberada',
          )
        : DoctorCheck(
            code: 'D044',
            title: 'Web: CORS da ingestão',
            status: CheckStatus.error,
            detail: '$origin não está liberada (resposta: '
                '${allowed ?? 'sem Access-Control-Allow-Origin'}). Na web '
                'nada será enviado.',
            fix: 'Peça a inclusão de $origin em AEGIS_CORS_ORIGINS no deploy '
                'da API.',
          );
  } catch (error) {
    return DoctorCheck(
      code: 'D044',
      title: 'Web: CORS da ingestão',
      status: CheckStatus.error,
      detail: '$error',
    );
  }
}
