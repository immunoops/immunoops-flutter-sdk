import 'telemetry_store_memory.dart'
    if (dart.library.io) 'telemetry_store_io.dart' as impl;

/// Where unsent items and the install id survive an app restart. On the
/// web nothing survives: there is no file system, and local storage would
/// keep the install id across users of a shared browser.
abstract class TelemetryStore {
  Future<List<Map<String, Object?>>> loadQueue();
  Future<void> saveQueue(List<Map<String, Object?>> items);
  Future<String?> readInstallId();
  Future<void> writeInstallId(String id);

  factory TelemetryStore.platform() => impl.createStore();
}

/// Keeps everything in memory; used on the web and in tests.
class MemoryTelemetryStore implements TelemetryStore {
  List<Map<String, Object?>> queue = [];
  String? installId;

  @override
  Future<List<Map<String, Object?>>> loadQueue() async => List.of(queue);

  @override
  Future<void> saveQueue(List<Map<String, Object?>> items) async {
    queue = List.of(items);
  }

  @override
  Future<String?> readInstallId() async => installId;

  @override
  Future<void> writeInstallId(String id) async => installId = id;
}
