# Builds lib/features/chat_view/emoji_names.dart (ADR-049) from Unicode CLDR
# annotations (en, ru; cldr-json, Unicode License v3) and emoji-data.txt.
# Usage: python3 tool/emoji_names.py lib/features/chat_view/emoji_data.dart <dir> lib/features/chat_view/emoji_names.dart
# where <dir> holds ann_en.json / ann_ru.json (cldr-annotations-full), annd_en.json / annd_ru.json
# (cldr-annotations-derived-full) and emoji-data.txt (unicode.org/Public/15.1.0/ucd/emoji/).
import json, re, sys
src, dl, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding='utf-8').read()
body = text[text.index('const _kEmoji'):]
emoji = []
for s in re.findall(r"'([^']*)'", body):
    emoji += [e for e in s.split(' ') if e]
emoji = list(dict.fromkeys(emoji))  # one entry per emoji (a few sit in two categories)
def load(l):
    d = {}
    for f in (f'{dl}/ann_{l}.json', f'{dl}/annd_{l}.json'):
        j = json.load(open(f, encoding='utf-8'))
        a = j['annotations'] if 'annotations' in j else j['annotationsDerived']
        a = a['annotations'] if 'annotations' in a else a
        for k, v in a.items():
            d[k] = v
    return d
en, ru = load('en'), load('ru')
def look(d, e):
    return d.get(e) or d.get(e.replace('️', '')) or {}
def words(v):
    parts = list(v.get('tts', [])) + list(v.get('default', []))[:6]
    seen = []
    for p in parts:
        p = p.lower().replace('|', ' ').replace("'", ' ')
        if p not in seen: seen.append(p)
    return ' '.join(seen)
# Emoji_Modifier_Base codepoints
bases = set()
for line in open(f'{dl}/emoji-data.txt', encoding='utf-8'):
    line = line.split('#')[0].strip()
    if not line or 'Emoji_Modifier_Base' not in line: continue
    r = line.split(';')[0].strip()
    if '..' in r:
        a, b = r.split('..'); bases.update(range(int(a, 16), int(b, 16) + 1))
    else: bases.add(int(r, 16))
toned = []
lines = []
miss = 0
for e in emoji:
    w = (words(look(en, e)) + ' ' + words(look(ru, e))).strip()
    if not w: miss += 1; continue
    lines.append(f"  '{e}': '{w}',")
    cps = [ord(c) for c in e if ord(c) != 0xfe0f]
    if len(cps) == 1 and cps[0] in bases: toned.append(e)
dart = f"""// Emoji names for the panel's search, English and Russian, and which
// emoji take a skin tone. Generated from Unicode CLDR annotations
// (cldr-json, Unicode License v3) and emoji-data.txt (Unicode 15.1)
// for the emoji in emoji_data.dart — do not edit by hand.

/// Lower-case search words per emoji ("grinning face … улыбка …").
const kEmojiNames = <String, String>{{
{chr(10).join(lines)}
}};

/// Emoji that take a skin-tone modifier (one code point, Emoji_Modifier_Base).
const kSkinToneEmoji = <String>{{{', '.join("'" + e + "'" for e in toned)}}};
"""
open(out, 'w', encoding='utf-8').write(dart)
print(len(emoji), 'emoji;', miss, 'without names;', len(toned), 'toned')
