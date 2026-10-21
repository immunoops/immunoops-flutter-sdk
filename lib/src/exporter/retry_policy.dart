import 'dart:math';

/// Exponential back-off with jitter: 5 s, 10 s, 20 s... up to 5 min, plus
/// up to 20 % random so thousands of devices coming back online do not
/// retry at the same second.
class RetryPolicy {
  const RetryPolicy({
    this.base = const Duration(seconds: 5),
    this.maxDelay = const Duration(minutes: 5),
    this.jitter = 0.2,
  });

  final Duration base;
  final Duration maxDelay;
  final double jitter;

  /// Wait after the [failures]-th consecutive failure (1 for the first).
  Duration delay(int failures, Random random) {
    final factor = pow(2, min(max(failures - 1, 0), 16)).toInt();
    final ms = min(base.inMilliseconds * factor, maxDelay.inMilliseconds);
    return Duration(
        milliseconds: (ms * (1 + random.nextDouble() * jitter)).round());
  }
}
