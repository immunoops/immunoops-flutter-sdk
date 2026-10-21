import 'dart:io';

/// Resident memory of this process, in bytes.
int? currentRssBytes() {
  try {
    final rss = ProcessInfo.currentRss;
    return rss > 0 ? rss : null;
  } catch (_) {
    return null;
  }
}
