// Contact QR — "My QR code" shows it, the camera in New chat reads it.
//
//   sinhron-contact:<identity key, 64 hex>@<server host>?n=<their name>
//
// The key is what "Start chat by key" takes; the host says which server the
// person is on (chats only work between people on the same server); the
// name (optional, URL-encoded) names the new chat at once instead of
// "Chat <key>". Not a key exchange: the safety number is still how you
// verify who it is.

import 'package:flutter/widgets.dart' show StringCharacters;

const kContactQrPrefix = 'sinhron-contact:';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

String contactQrPayload(String identityHex, String serverHost, {String name = ''}) {
  final n = name.trim();
  return '$kContactQrPrefix${identityHex.toLowerCase()}@$serverHost'
      '${n.isEmpty ? '' : '?n=${Uri.encodeQueryComponent(n)}'}';
}

/// A scanned contact: whose key, the server they said they are on and
/// their name (null for a bare key / an older code).
typedef ContactQr = ({String identityHex, String? serverHost, String? name});

/// The QR's text → contact, or null if it is not a Sinhron contact.
/// A bare 64-hex key (copied from "Copy key") is accepted too.
ContactQr? parseContactQr(String text) {
  var t = text.trim();
  if (_hex64.hasMatch(t.toLowerCase())) return (identityHex: t.toLowerCase(), serverHost: null, name: null);
  if (!t.startsWith(kContactQrPrefix)) return null;
  t = t.substring(kContactQrPrefix.length);
  String? name;
  final q = t.indexOf('?');
  if (q >= 0) {
    final query = t.substring(q + 1);
    t = t.substring(0, q);
    String n;
    try {
      n = Uri.splitQueryString(query)['n']?.trim() ?? '';
    } catch (_) {
      // Not URL-encoded (another app made the code): take it as is.
      n = query.startsWith('n=') ? query.substring(2).trim() : '';
    }
    // A name, not a page of text: one line, at most 64 characters.
    if (n.isNotEmpty) name = n.replaceAll(RegExp(r'\s+'), ' ').characters.take(64).toString();
  }
  final at = t.indexOf('@');
  final key = (at < 0 ? t : t.substring(0, at)).toLowerCase();
  if (!_hex64.hasMatch(key)) return null;
  final host = at < 0 ? '' : t.substring(at + 1).trim().toLowerCase();
  return (identityHex: key, serverHost: host.isEmpty ? null : host, name: name);
}

/// A shared contact in a chat ("Share contact" sends [contactQrPayload] as
/// the whole message): the contact, or null for any other text. A bare key
/// or a payload with words around it stays text.
ContactQr? contactCardOf(String text) {
  final t = text.trim();
  if (!t.startsWith(kContactQrPrefix) || t.contains(RegExp(r'\s'))) return null;
  return parseContactQr(t);
}

/// `aaaa bbbb cccc dddd` — the start of a key, for people to compare by eye.
String keyFingerprint(String identityHex) {
  final s = identityHex.length > 16 ? identityHex.substring(0, 16) : identityHex;
  return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4 > s.length ? s.length : i + 4)].join(' ');
}
