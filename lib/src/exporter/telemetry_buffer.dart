import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/diagnostics.dart';
import '../core/telemetry_item.dart';
import 'telemetry_store.dart';
import 'ingest_exporter.dart';
import 'retry_policy.dart';

/// Owns the queue: batches items, sends them on a timer, backs off on
/// failure, and keeps unsent items on disk so a restart does not lose them.
class TelemetryBuffer {
  TelemetryBuffer({
    required this.transport,
    required this.store,
    required this.appName,
    required this.diagnostics,
    this.maxBatchSize = 100,
    this.maxQueueSize = 2000,
    this.flushInterval = const Duration(seconds: 10),
    this.retryPolicy = const RetryPolicy(),
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random();

  final IngestExporter transport;
  final TelemetryStore store;
  final String appName;
  final DiagnosticsHub diagnostics;
  final int maxBatchSize;
  final int maxQueueSize;
  final Duration flushInterval;
  final RetryPolicy retryPolicy;
  final DateTime Function() _now;
  final Random _random;

  final _queue = <TelemetryItem>[];
  // Items of the batch being sent; trimming a full queue never drops them.
  int _inFlightCount = 0;
  // Bumped by clear(), so a send that returns afterwards leaves the new
  // queue alone.
  int _generation = 0;
  Timer? _timer;
  Future<void>? _inFlight;
  DateTime? _retryAt;
  int _failures = 0;
  bool _blocked = false;
  bool _onDisk = false;

  int sent = 0;
  int dropped = 0;

  int get queued => _queue.length;
  bool get blocked => _blocked;

  /// Loads what a previous run left on disk and starts the timer.
  /// [autoFlush] false leaves the timing to the caller (the client ticks
  /// it after collecting frame counts).
  Future<void> start({bool autoFlush = true}) async {
    final stored = await store.loadQueue();
    if (stored.isNotEmpty) {
      _onDisk = true;
      final restored = stored
          .map(TelemetryItem.fromJson)
          .whereType<TelemetryItem>()
          .toList();
      // Older items go first, then whatever arrived during start-up.
      final pending = _queue.toList();
      _queue
        ..clear()
        ..addAll(restored)
        ..addAll(pending);
      _trim();
    }
    if (autoFlush) _timer ??= Timer.periodic(flushInterval, (_) => flush());
  }

  void add(TelemetryItem item) {
    if (_blocked) return;
    _queue.add(item);
    _trim();
    if (_queue.length >= maxBatchSize) scheduleMicrotask(flush);
  }

  void _trim() {
    var removed = 0;
    while (_queue.length > maxQueueSize && _queue.length > _inFlightCount) {
      _queue.removeAt(_inFlightCount);
      removed++;
    }
    if (removed > 0) {
      dropped += removed;
      diagnostics.report(Diagnostics.queueFull);
    }
  }

  /// Sends everything queued, one batch at a time. [force] skips the
  /// back-off wait (app going to background, shutdown).
  Future<void> flush({bool force = false}) {
    if (_inFlight != null) return _inFlight!;
    if (_blocked || _queue.isEmpty) return Future.value();
    final retryAt = _retryAt;
    if (!force && retryAt != null && _now().isBefore(retryAt)) {
      return Future.value();
    }
    return _inFlight = _drain().whenComplete(() => _inFlight = null);
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_blocked) {
      final generation = _generation;
      final batch = _queue.take(maxBatchSize).toList();
      _inFlightCount = batch.length;
      final SendResult result;
      try {
        result = await transport.send(buildIngestPayload(appName, batch));
      } finally {
        _inFlightCount = 0;
      }
      if (generation != _generation) return;
      switch (result.outcome) {
        case SendOutcome.sent:
          _removeFront(batch.length);
          sent += batch.length;
          _failures = 0;
          _retryAt = null;
          diagnostics.clear('IMMUNO-E002');
          diagnostics.trace('lote enviado: ${batch.length} itens');
        case SendOutcome.rejected:
          _removeFront(batch.length);
          dropped += batch.length;
          diagnostics.report(
            Diagnostics.batchRejected(result.statusCode, result.detail),
          );
        case SendOutcome.unauthorized:
          dropped += _queue.length;
          _queue.clear();
          _blocked = true;
          diagnostics.report(Diagnostics.keyRejected(result.statusCode));
          await persist();
          return;
        case SendOutcome.retry:
          _failures++;
          _retryAt = _now().add(retryPolicy.delay(_failures, _random));
          diagnostics.report(Diagnostics.unreachable(
            result.statusCode == null
                ? result.detail
                : 'HTTP ${result.statusCode}',
          ));
          await persist();
          return;
      }
    }
    if (_onDisk) await persist();
  }

  void _removeFront(int count) =>
      _queue.removeRange(0, min(count, _queue.length));

  /// Writes the queue to disk (or removes the file when it is empty).
  Future<void> persist() async {
    try {
      final stored = <Map<String, Object?>>[];
      for (final item in _queue) {
        final json = item.toStoredJson();
        try {
          jsonEncode(json);
          stored.add(json);
        } catch (_) {
          // One bad item must not keep the rest off the disk.
        }
      }
      await store.saveQueue(stored);
      _onDisk = _queue.isNotEmpty;
    } catch (_) {
      // Disk full or sandbox denied: the queue stays in memory.
    }
  }

  /// Drops everything queued and on disk (consent withdrawn).
  Future<void> clear() async {
    _generation++;
    _queue.clear();
    await persist();
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    _timer = null;
    await flush(force: true);
    await persist();
  }
}
