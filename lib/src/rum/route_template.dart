final _numeric = RegExp(r'^\d+$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _hexId = RegExp(r'^[0-9a-f]{16,}$', caseSensitive: false);
final _opaqueId = RegExp(r'^(?=.*\d)[A-Za-z0-9_\-]{20,}$');

/// Turns a concrete path into its template, so `/aulas/123` and
/// `/aulas/456` are the same screen or route, and no id or token from a
/// URL is ever sent.
String normalizePath(String path) {
  var clean = path;
  final cut = clean.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) clean = clean.substring(0, cut);
  final segments = clean.split('/').map((segment) {
    if (segment.isEmpty || segment.startsWith(':')) return segment;
    if (_numeric.hasMatch(segment) ||
        _uuid.hasMatch(segment) ||
        _hexId.hasMatch(segment) ||
        _opaqueId.hasMatch(segment)) {
      return ':id';
    }
    return segment;
  });
  final result = segments.join('/');
  if (result.isEmpty) return '/';
  return result.length > 120 ? result.substring(0, 120) : result;
}

/// Screen name from a route's settings name: go_router names its pages
/// after the route name or the route template.
String? screenNameFrom(String? settingsName) {
  if (settingsName == null || settingsName.trim().isEmpty) return null;
  final name = settingsName.trim();
  return name.contains('/') ? normalizePath(name) : name;
}
