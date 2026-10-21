import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immunoops_flutter/src/doctor/checks.dart';
import 'package:immunoops_flutter/src/doctor/doctor.dart';
import 'package:yaml/yaml.dart';

/// A throwaway app project: path → contents.
Directory _project(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('doctor');
  for (final MapEntry(key: path, value: contents) in files.entries) {
    File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }
  return dir;
}

const _pubspec = '''
name: app
dependencies:
  flutter:
    sdk: flutter
  immunoops_flutter:
    path: ../immunoops_flutter
''';

const _goodMain = '''
import 'package:immunoops_flutter/immunoops_flutter.dart';
void main() {
  ImmunoOps.init(const ImmunoOpsConfig(clientKey: 'k', appName: 'a'),
      appRunner: () => runApp(const App()));
}
''';

Map<String, DoctorCheck> _byCode(List<DoctorCheck> checks) =>
    {for (final c in checks) c.code: c};

Future<Map<String, DoctorCheck>> _run(
  Map<String, String> files, {
  String? key,
  String? origin,
  bool sendTest = false,
  http.Client? client,
  String dart = '3.8.0',
}) async {
  final dir = _project(files);
  addTearDown(() => dir.deleteSync(recursive: true));
  return _byCode(await runDoctor(DoctorOptions(
    projectDir: dir,
    clientKey: key ?? '',
    webOrigin: origin,
    sendTest: sendTest,
    dartVersion: dart,
    httpClient: client,
  )));
}

void main() {
  test('a fully integrated app passes', () async {
    final checks = await _run({
      'pubspec.yaml': _pubspec,
      'pubspec.lock': 'packages:\n  immunoops_flutter:\n',
      'lib/main.dart': _goodMain,
      'lib/router.dart':
          'final r = GoRouter(observers: [ImmunoOps.navigatorObserver]);',
      'lib/api.dart':
          'final d = Dio()..interceptors.add(ImmunoOpsDioInterceptor());',
      'android/app/src/main/AndroidManifest.xml':
          '<uses-permission android:name="android.permission.INTERNET"/>',
    });
    expect(
      checks.values.where((c) =>
          c.status == CheckStatus.error || c.status == CheckStatus.warning),
      isEmpty,
    );
    expect(checks['D010']!.detail, 'lib/main.dart');
  });

  test('missing pieces are each reported with a fix', () async {
    final checks = await _run({
      'pubspec.yaml': 'name: app\ndependencies:\n  dio: ^5.0.0\n',
      'lib/main.dart': 'void main() => runApp(const App());',
      'lib/a.dart': 'final d = Dio();',
      'lib/b.dart': '// Dio( in a comment does not count\nfinal x = 1;',
      'lib/c.dart': 'final r = await http.get(Uri.parse("x"));',
      'lib/d.dart': 'void f() { FlutterError.onError = (_) {}; }',
      'android/app/src/main/AndroidManifest.xml': '<manifest/>',
      'android/app/build.gradle.kts': 'minSdk = 19',
    });
    expect(checks['D001']!.status, CheckStatus.error);
    expect(checks['D010']!.status, CheckStatus.error);
    expect(checks['D011']!.status, CheckStatus.warning);
    expect(checks['D012']!.status, CheckStatus.warning);
    expect(checks['D012']!.detail, contains('lib/a.dart'));
    expect(checks['D012']!.detail, isNot(contains('lib/b.dart')));
    expect(checks['D013']!.detail, contains('lib/c.dart'));
    expect(checks['D014']!.detail, contains('lib/d.dart'));
    expect(checks['D020']!.status, CheckStatus.error);
    expect(checks['D021']!.status, CheckStatus.warning);
    for (final check in checks.values) {
      if (check.status == CheckStatus.error ||
          check.status == CheckStatus.warning) {
        expect(check.fix, isNotNull, reason: '${check.code} needs a fix');
      }
    }
  });

  test('runApp before init without appRunner is a warning', () async {
    final checks = await _run({
      'pubspec.yaml': _pubspec,
      'lib/main.dart': 'void main() { runApp(App()); ImmunoOps.init(o); }',
    });
    expect(checks['D010']!.status, CheckStatus.warning);
  });

  test('a ShellRoute with a single observer is flagged', () async {
    final checks = await _run({
      'pubspec.yaml': _pubspec,
      'lib/main.dart': _goodMain,
      'lib/router.dart': '''
final r = GoRouter(observers: [ImmunoOps.navigatorObserver], routes: [
  StatefulShellRoute.indexedStack(branches: []),
]);''',
    });
    expect(checks['D011']!.status, CheckStatus.warning);
    expect(checks['D011']!.detail, contains('ShellRoute'));
  });

  test('a version the SDK cannot use is a conflict', () async {
    final checks = await _run({
      'pubspec.yaml': '$_pubspec  package_info_plus: ^5.0.0\n  dio: ^5.9.0\n',
      'lib/main.dart': _goodMain,
    });
    expect(checks['D003']!.status, CheckStatus.error);
    expect(checks['D003']!.detail, contains('package_info_plus'));
    expect(checks['D003']!.detail, isNot(contains('dio')));
  });

  test('an old Dart is an error', () async {
    final checks = await _run(
      {'pubspec.yaml': _pubspec, 'lib/main.dart': _goodMain},
      dart: '3.4.0',
    );
    expect(checks['D002']!.status, CheckStatus.error);
  });

  test('obfuscated release builds are flagged', () async {
    final checks = await _run({
      'pubspec.yaml': _pubspec,
      'lib/main.dart': _goodMain,
      'fastlane/Fastfile':
          'sh("flutter build ipa --obfuscate --split-debug-info=build/sym")',
    });
    expect(checks['D030']!.status, CheckStatus.warning);
    expect(checks['D030']!.detail, contains('fastlane/Fastfile'));
  });

  group('connection', () {
    const key = 'eyJjbHVzdGVyX25hbWUiOiJjcmlhLWFwcCJ9.c2ln';

    test('the test send proves the key', () async {
      late http.Request seen;
      final checks = await _run(
        {'pubspec.yaml': _pubspec, 'lib/main.dart': _goodMain},
        key: key,
        sendTest: true,
        client: MockClient((request) async {
          seen = request;
          return http.Response('{"status":"ok"}', 200);
        }),
      );
      expect(checks['D041']!.detail, 'Conexão "cria-app"');
      expect(checks['D043']!.status, CheckStatus.ok);
      expect(seen.headers['Authorization'], 'Bearer $key');
      expect(seen.url.path, '/agent/ingest/v1/custom');
    });

    test('a rejected key says to copy it again', () async {
      final checks = await _run(
        {'pubspec.yaml': _pubspec, 'lib/main.dart': _goodMain},
        key: key,
        sendTest: true,
        client: MockClient((_) async => http.Response('unauthorized', 401)),
      );
      expect(checks['D043']!.status, CheckStatus.error);
      expect(checks['D043']!.fix, contains('copie de novo'));
    });

    test('CORS: allowed origin, missing origin and a 405 preflight', () async {
      Future<DoctorCheck> preflight(int status, String? allow) async =>
          (await _run(
            {'pubspec.yaml': _pubspec, 'web/index.html': ''},
            origin: 'https://app.cria.com',
            client: MockClient((_) async => http.Response('', status, headers: {
                  if (allow != null) 'access-control-allow-origin': allow,
                })),
          ))['D044']!;

      expect((await preflight(204, 'https://app.cria.com')).status,
          CheckStatus.ok);
      expect((await preflight(204, null)).status, CheckStatus.error);
      final blocked = await preflight(405, 'https://app.cria.com');
      expect(blocked.status, CheckStatus.error);
      expect(blocked.detail, contains('405'));
    });

    test('without a key nothing is sent', () async {
      var calls = 0;
      final checks = await _run(
        {'pubspec.yaml': _pubspec, 'lib/main.dart': _goodMain},
        client: MockClient((_) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      expect(checks['D040']!.status, CheckStatus.info);
      expect(calls, 0);
    });
  });

  test('the ranges the doctor knows match pubspec.yaml', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final deps = Map<String, Object?>.from(pubspec['dependencies'] as YamlMap)
      ..remove('flutter');
    expect(deps, sdkDependencyRanges);
  });

  test('the doctor never imports Flutter (it runs with dart run)', () {
    final files = Directory('lib/src/doctor')
        .listSync()
        .whereType<File>()
        .followedBy([File('bin/doctor.dart')]);
    for (final file in files) {
      expect(
          file.readAsStringSync(), isNot(contains("import 'package:flutter")),
          reason: file.path);
    }
  });
}
