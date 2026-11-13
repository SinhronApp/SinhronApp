# Builds assets/stickers/ (ADR-049) — the built-in sticker packs — from files
# downloaded one by one (no bulk scraping):
#   • Noto Emoji Animation (Google, CC BY 4.0 — googlefonts.github.io/noto-emoji-files):
#     https://fonts.gstatic.com/s/e/notoemoji/latest/<codepoint>/lottie.json, gzipped
#     (`gzip -9`) into <dl>/noto/<codepoint>.tgs;
#   • Fluent Emoji 3D (Microsoft, MIT — github.com/microsoft/fluentui-emoji):
#     assets/<Name>/3D/<name>_3d.png + metadata.json, converted with
#     `cwebp -q 90 -alpha_q 100 -m 6` into <dl>/fluent/<name>.webp.
# Usage: python3 tool/sticker_packs.py <dl> assets/stickers
import json, os, shutil, sys
dl, out = sys.argv[1], sys.argv[2]
def ch(cp): return ''.join(chr(int(x, 16)) for x in cp.split('_'))
faces = '1f600 1f602 1f923 1f60a 1f60d 1f618 1f970 1f929 1f60e 1f914 1f928 1f644 1f60f 1f62d 1f622 1f97a 1f621 1f92f 1f631 1f973 1f634 1f92e 1f921 1f47b 1f480 1f608 1f917 1f92b 1f605 1f609 1f643 1f972 1f92a 1f60b 1f633 1f62c 1f971 1f975 1f976 1f911 1f913 1f9d0 1f62e 1f63b 1f62e_200d_1f4a8'.split()
gest = '1f44d 1f44e 1f44f 1f64f 1f44b 270c_fe0f 1f91d 1f4aa 1f918 1f64c 1f90c 1f44c 1f483 1f525 2764_fe0f 1f494 1f496 1f4af 1f389 2728 1f680 1f381 1f382 1f440 1f648 1f4a9 1f308'.split()
fluent = 'dog_face cat_face fox panda unicorn frog penguin owl octopus koala tiger_face hamster rabbit_face bear monkey_face pizza hot_beverage birthday_cake avocado watermelon doughnut rocket crown gem_stone balloon trophy light_bulb party_popper alien robot sun_with_face rainbow four_leaf_clover cactus snowman christmas_tree'.split()
packs = []
def noto(pid, title_ru, title_en, cps):
    d = os.path.join(out, pid); os.makedirs(d, exist_ok=True)
    st = []
    for cp in cps:
        shutil.copy(f'{dl}/noto/{cp}.tgs', f'{d}/{cp}.tgs')
        st.append({'file': f'{cp}.tgs', 'emoji': ch(cp)})
    packs.append({'id': f'sinhron.{pid}', 'dir': pid, 'title': {'ru': title_ru, 'en': title_en},
                  'author': 'Google — Noto Emoji Animation', 'license': 'CC BY 4.0',
                  'license_url': 'https://creativecommons.org/licenses/by/4.0/', 'stickers': st})
noto('noto_faces', 'Эмоции', 'Feelings', faces)
noto('noto_gestures', 'Жесты и праздник', 'Hands & party', gest)
d = os.path.join(out, 'fluent_3d'); os.makedirs(d, exist_ok=True)
st = []
for n in fluent:
    shutil.copy(f'{dl}/fluent/{n}.webp', f'{d}/{n}.webp')
    st.append({'file': f'{n}.webp', 'emoji': json.load(open(f'{dl}/fluent/{n}.meta.json'))['glyph']})
packs.append({'id': 'sinhron.fluent_3d', 'dir': 'fluent_3d', 'title': {'ru': 'Зверята и вещи', 'en': 'Critters & things'},
              'author': 'Microsoft — Fluent Emoji', 'license': 'MIT',
              'license_url': 'https://github.com/microsoft/fluentui-emoji/blob/main/LICENSE', 'stickers': st})
json.dump({'v': 1, 'packs': packs}, open(os.path.join(out, 'packs.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(sum(len(p['stickers']) for p in packs))
