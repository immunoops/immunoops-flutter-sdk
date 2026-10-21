import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../diagnostics.dart';
import '../semconv.dart';
import '../version.dart';

/// Attributes every item carries: who sent it, from which build, on which
/// device. Read once at start-up; plugin failures leave a field out
/// instead of failing init.
class AppContext {
  AppContext({
    required this.appName,
    required this.environment,
    this.appVersion,
    this.appBuild,
    this.osName,
    this.osVersion,
    this.deviceModel,
    this.deviceManufacturer,
    this.physicalDevice,
  });

  final String appName;
  final String environment;
  final String? appVersion;
  final String? appBuild;
  final String? osName;
  final String? osVersion;
  final String? deviceModel;
  final String? deviceManufacturer;
  final bool? physicalDevice;

  String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  /// Low-cardinality tags for metrics: no session or install id, so the
  /// console can group by any of them.
  Map<String, String> get metricTags => {
        Attr.serviceName: appName,
        if (appVersion != null) Attr.serviceVersion: appVersion!,
        if (appBuild != null) Attr.appBuild: appBuild!,
        Attr.platform: platform,
        if (osName != null) Attr.osName: osName!,
        if (osVersion != null) Attr.osVersion: osVersion!,
        if (deviceModel != null) Attr.deviceModel: deviceModel!,
        Attr.environment: environment,
        Attr.sdkVersion: sdkVersion,
      };

  /// Full context for logs and events.
  Map<String, Object?> context({String? sessionId, String? installId}) => {
        ...metricTags,
        if (deviceManufacturer != null)
          Attr.deviceManufacturer: deviceManufacturer,
        if (physicalDevice != null) Attr.devicePhysical: physicalDevice,
        Attr.sdkName: sdkName,
        Attr.sdkLanguage: 'dart',
        if (sessionId != null) Attr.sessionId: sessionId,
        if (installId != null) Attr.installId: installId,
      };

  static Future<AppContext> collect({
    required String appName,
    required String environment,
    required DiagnosticsHub diagnostics,
  }) async {
    String? version;
    String? build;
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version.isEmpty ? null : info.version;
      build = info.buildNumber.isEmpty ? null : info.buildNumber;
    } on MissingPluginException {
      diagnostics.report(Diagnostics.pluginUnavailable('package_info_plus'));
    } catch (_) {
      // Answered without data: the version tags are left out.
    }

    String? osName;
    String? osVersion;
    String? model;
    String? manufacturer;
    bool? physical;
    try {
      final plugin = DeviceInfoPlugin();
      if (kIsWeb) {
        final web = await plugin.webBrowserInfo;
        osName = 'web';
        osVersion = web.browserName.name;
        model = web.platform;
      } else {
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
            final android = await plugin.androidInfo;
            osName = 'android';
            osVersion = android.version.release;
            model = android.model;
            manufacturer = android.manufacturer;
            physical = android.isPhysicalDevice;
          case TargetPlatform.iOS:
            final ios = await plugin.iosInfo;
            osName = 'ios';
            osVersion = ios.systemVersion;
            model = ios.utsname.machine;
            manufacturer = 'Apple';
            physical = ios.isPhysicalDevice;
          case TargetPlatform.macOS:
            final mac = await plugin.macOsInfo;
            osName = 'macos';
            osVersion = mac.osRelease;
            model = mac.model;
            manufacturer = 'Apple';
          default:
            osName = defaultTargetPlatform.name;
        }
      }
    } on MissingPluginException {
      diagnostics.report(Diagnostics.pluginUnavailable('device_info_plus'));
    } catch (_) {
      // Answered without data: the device tags are left out.
    }
    osName ??= kIsWeb ? 'web' : defaultTargetPlatform.name;

    return AppContext(
      appName: appName,
      environment: environment,
      appVersion: version,
      appBuild: build,
      osName: osName,
      osVersion: osVersion,
      deviceModel: model,
      deviceManufacturer: manufacturer,
      physicalDevice: physical,
    );
  }
}

/// 128 random bits as hex: session and install ids, never derived from
/// anything that identifies the user or the device.
String randomId([Random? random]) {
  final rng = random ?? Random.secure();
  return List.generate(
      16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
