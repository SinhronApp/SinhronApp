// @-mentions in group chats — tech-debt 2.21.
//
// On the wire (inside the encrypted text) a mention is `@[<identity key>]`:
// the key never changes, while names do and can repeat. Everyone renders
// it with the name that person shared (`profile`), or a short key. The
// composer shows "@Name" and turns it into the token on send.

final RegExp mentionToken = RegExp(r'@\[([0-9a-f]{64})\]');

String mentionOf(String identityKeyHex) => '@[$identityKeyHex]';

/// Does [text] mention [identityKeyHex]?
bool mentionsKey(String text, String? identityKeyHex) =>
    identityKeyHex != null && identityKeyHex.isNotEmpty && text.contains(mentionOf(identityKeyHex));

/// Tokens → "@Name" (for previews, copy, notifications).
String mentionsToDisplay(String text, String Function(String key) nameOf) =>
    text.replaceAllMapped(mentionToken, (m) => '@${nameOf(m.group(1)!)}');

/// "@Name" → tokens, for the names picked in the composer ([picked]:
/// display name → identity key). Longest names first, so "@Ann Lee" wins
/// over "@Ann"; a name only counts as a whole word.
String encodeMentions(String text, Map<String, String> picked) {
  if (picked.isEmpty) return text;
  final names = picked.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  final pattern = RegExp('@(${names.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}_])', unicode: true);
  return text.replaceAllMapped(pattern, (m) => mentionOf(picked[m.group(1)!]!));
}

/// A stored text back to what the composer shows when editing, plus the
/// name → key map that [encodeMentions] needs to restore the tokens.
(String, Map<String, String>) decodeForEditing(String text, String Function(String key) nameOf) {
  final picked = <String, String>{};
  final shown = text.replaceAllMapped(mentionToken, (m) {
    final key = m.group(1)!;
    final name = nameOf(key);
    picked[name] = key;
    return '@$name';
  });
  return (shown, picked);
}
