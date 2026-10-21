// Same rules as sdk/node/src/sanitizer.ts, with two deliberate changes:
// short key fragments (rg, pin, pwd) only match a whole word of the key,
// so "charge" or "shipping" are kept; and a digit run only counts as a
// card number when it starts like one and passes the Luhn check, so
// timestamps and order numbers survive.

const redacted = '[REDACTED_BY_IMMUNOOPS_LGPD]';

final _cpf = RegExp(r'\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b');
final _cardCandidate = RegExp(r'\b(?:\d[ -]?){12,18}\d\b');
final _bearer = RegExp(
  r'Bearer\s+[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+\.?[A-Za-z0-9\-_.+/=]*',
  caseSensitive: false,
);
final _urlQuery = RegExp(r'''(https?://[^\s?#'"<>]+)[?#][^\s'"<>]*''');
final _email = RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');

const _sensitiveFragments = [
  'password',
  'passwd',
  'senha',
  'secret',
  'token',
  'apikey',
  'authorization',
  'bearer',
  'creditcard',
  'cardnumber',
  'cartao',
  'cvv',
  'cvc',
  'cpf',
  'cnpj',
  'ssn',
  'docnumber',
  'documentnumber',
  'privatekey',
];

const _sensitiveWords = {'pwd', 'pin', 'rg', 'auth', 'document'};

/// Whether a map key names data that must never leave the device.
bool isSensitiveKey(String key) {
  if (key.isEmpty) return false;
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[-_ .\t]'), '');
  if (_sensitiveFragments.any(normalized.contains)) return true;
  final words = key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'));
  return words.any(_sensitiveWords.contains);
}

/// Masks URL query strings, CPF, card numbers, e-mails and bearer tokens
/// inside free text.
String sanitizeString(String text) {
  if (text.isEmpty) return text;
  // Query strings carry tokens and signed URLs; error messages of the http
  // packages print the full URL.
  var result = text.replaceAllMapped(_urlQuery, (m) => '${m[1]}?[REDACTED]');
  result = result.replaceAll(_cpf, '***.***.***-**');
  result = result.replaceAllMapped(_cardCandidate, (m) {
    final digits = m[0]!.replaceAll(RegExp(r'\D'), '');
    // Card networks start with 2 to 6 (Mastercard, Amex, Visa, Elo,
    // Discover); epoch-millisecond timestamps start with 1.
    final network = '23456'.contains(digits[0]);
    return digits.length >= 13 &&
            digits.length <= 19 &&
            network &&
            _luhn(digits)
        ? '****-****-****-****'
        : m[0]!;
  });
  result = result.replaceAll(_bearer, 'Bearer [REDACTED]');
  return result.replaceAll(_email, '[EMAIL]');
}

/// Applies [sanitizeString] to every string and redacts sensitive keys,
/// recursively through maps and lists.
Object? sanitizeValue(Object? value) {
  if (value is String) return sanitizeString(value);
  if (value is Map) {
    return {
      for (final e in value.entries)
        '${e.key}':
            isSensitiveKey('${e.key}') ? redacted : sanitizeValue(e.value),
    };
  }
  if (value is Iterable) return value.map(sanitizeValue).toList();
  return value;
}

Map<String, Object?> sanitizeMap(Map<String, Object?> map) =>
    sanitizeValue(map)! as Map<String, Object?>;

bool _luhn(String digits) {
  var sum = 0;
  var doubleIt = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var d = digits.codeUnitAt(i) - 48;
    if (doubleIt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    doubleIt = !doubleIt;
  }
  return sum % 10 == 0;
}
