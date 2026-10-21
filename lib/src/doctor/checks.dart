// The doctor runs with `dart run`, outside Flutter: nothing under
// lib/src/doctor may import package:flutter.

enum CheckStatus { ok, info, warning, error }

/// One line of the doctor's report.
class DoctorCheck {
  const DoctorCheck({
    required this.code,
    required this.title,
    required this.status,
    this.detail,
    this.fix,
  });

  final String code;
  final String title;
  final CheckStatus status;
  final String? detail;
  final String? fix;

  Map<String, Object?> toJson() => {
        'code': code,
        'title': title,
        'status': status.name,
        if (detail != null) 'detail': detail,
        if (fix != null) 'fix': fix,
      };
}

/// The SDK's own dependency ranges, mirrored from pubspec.yaml so the
/// doctor can compare them with the app's; test/doctor_test.dart keeps
/// both in step.
const sdkDependencyRanges = {
  'battery_plus': '>=6.0.0 <8.0.0',
  'connectivity_plus': '>=6.0.0 <8.0.0',
  'device_info_plus': '>=11.0.0 <14.0.0',
  'dio': '>=5.4.0 <6.0.0',
  'http': '>=1.1.0 <2.0.0',
  'package_info_plus': '>=8.0.0 <11.0.0',
  'path_provider': '>=2.1.0 <3.0.0',
  'pub_semver': '>=2.1.0 <3.0.0',
  'yaml': '>=3.1.0 <4.0.0',
};

const minDartVersion = '3.5.0';
