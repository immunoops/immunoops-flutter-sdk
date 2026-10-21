import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'telemetry_store.dart';

TelemetryStore createStore() => FileTelemetryStore();

/// Files under the app support directory: `immunoops/queue.json` and
/// `immunoops/install_id`. Writes go through a temp file and a rename, so
/// a kill mid-write never leaves a half file behind.
class FileTelemetryStore implements TelemetryStore {
  FileTelemetryStore({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;
  Directory? _dir;

  Future<Directory> _root() async {
    final dir = _dir ??= Directory('${(await _baseDir()).path}/immunoops');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async =>
      File('${(await _root()).path}/$name');

  Future<void> _atomicWrite(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<List<Map<String, Object?>>> loadQueue() async {
    try {
      final file = await _file('queue.json');
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map) item.cast<String, Object?>(),
      ];
    } catch (_) {
      // A corrupt queue is dropped rather than blocking every start.
      return [];
    }
  }

  @override
  Future<void> saveQueue(List<Map<String, Object?>> items) async {
    final file = await _file('queue.json');
    if (items.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await _atomicWrite(file, jsonEncode(items));
  }

  @override
  Future<String?> readInstallId() async {
    try {
      final file = await _file('install_id');
      if (!await file.exists()) return null;
      final id = (await file.readAsString()).trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeInstallId(String id) async =>
      _atomicWrite(await _file('install_id'), id);
}
