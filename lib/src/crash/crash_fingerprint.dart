/// The id that groups the same failure across devices and runs: the
/// error's type, its first message line and the top three stack frames,
/// hashed. Line numbers inside the frames make a new release of the same
/// bug a new group, which is what release health wants.
String crashFingerprint(String type, String message, StackTrace? stack) {
  final frames = stack == null
      ? const <String>[]
      : _safeString(stack)
          .split('\n')
          .map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').trim())
          .where((l) => l.isNotEmpty)
          .take(3)
          .toList();
  return fnv1a('$type|$message|${frames.join('|')}');
}

/// FNV-1a, 32 bits, as hex. Unlike [String.hashCode] it is the same on
/// every device and every run, so the console can group equal errors.
String fnv1a(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    // hash * 16777619 (= 2^24 + 403), split so it stays exact on the web,
    // where numbers above 2^53 lose precision.
    hash = (((hash << 24) & 0xffffffff) + hash * 403) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _safeString(Object value) {
  try {
    return value.toString();
  } catch (_) {
    return value.runtimeType.toString();
  }
}
