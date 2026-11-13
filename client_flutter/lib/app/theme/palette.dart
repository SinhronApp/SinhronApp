// Named colours — UI backlog §5 item 39. Literal colours that repeat
// across screens live here once (const, so usable anywhere). Theme-
// dependent colours belong in DsTokens; this is the fixed palette
// (illustration tints, on-media white, scrims).

import 'package:flutter/widgets.dart';

/// Avatar tints: pale fill + coloured initials, light and dark theme.
/// The first (blue) is the app's own — Saved messages; people get the
/// rest, so with the default accent a name in a group never looks like a
/// link. Initials reach 4.5:1 on their fill and on the incoming bubble
/// (contrast_test.dart).
const kAvatarTints = <(Color, Color)>[
  (Color(0xFFE0E8FA), Color(0xFF2B55B5)),
  (Color(0xFFE9E3FB), Color(0xFF6540BF)),
  (Color(0xFFD9F0F1), Color(0xFF0F6770)),
  (Color(0xFFDFF1E3), Color(0xFF23703F)),
  (Color(0xFFFBE1EC), Color(0xFFB02A66)),
  (Color(0xFFFCE4DF), Color(0xFFB03E2B)),
  (Color(0xFFE3E8EF), Color(0xFF475569)), // slate
  (Color(0xFFE9F2D6), Color(0xFF4A6B0C)), // lime
];
const kAvatarTintsDark = <(Color, Color)>[
  (Color(0xFF1D2A47), Color(0xFF9DB9FF)),
  (Color(0xFF2A2347), Color(0xFFBBA6FF)),
  (Color(0xFF143338), Color(0xFF6FD3DC)),
  (Color(0xFF17331F), Color(0xFF7DD69A)),
  (Color(0xFF3D1D2D), Color(0xFFFF9CC4)),
  (Color(0xFF3F211B), Color(0xFFFFA08C)),
  (Color(0xFF242C38), Color(0xFFA9B8CC)),
  (Color(0xFF27331A), Color(0xFFB4D873)),
];

abstract final class DsPalette {
  static const alert = Color(0xFFE5484D);
  static const amber = Color(0xFFF59E0B);
  static const black = Color(0xFF000000);
  /// Dark glass behind a toast pill — reads on light and dark screens.
  static const toastGlass = Color(0xE61C1C20);
  static const black20 = Color(0x33000000);
  static const black30 = Color(0x4D000000);
  static const black40 = Color(0x66000000);
  static const black50 = Color(0x80000000);
  static const black60 = Color(0x99000000);
  static const black62 = Color(0x9E000000);
  static const black8 = Color(0x14000000);
  static const blue = Color(0xFF2D6FF7);
  static const blue10 = Color(0x1A2D6FF7);
  static const blue12 = Color(0x1F2D6FF7);
  static const blue18 = Color(0x2E2D6FF7);
  static const blue20 = Color(0x332D6FF7);
  static const blue30 = Color(0x4D2D6FF7);
  static const blue500 = Color(0xFF3B82F6);
  static const blue600 = Color(0xFF2563EB);
  static const blue600a10 = Color(0x1A2563EB);
  static const brown = Color(0xFFB45309);
  static const coral = Color(0xFFE0683B);
  static const crimson = Color(0xFFD03A3A);
  static const cyan = Color(0xFF22D3EE);
  static const danger = Color(0xFFE04A4A);
  static const danger10 = Color(0x1AE04A4A);
  static const emerald = Color(0xFF10B981);
  static const fuchsia = Color(0xFFC026D3);
  static const green = Color(0xFF1FAF6E);
  static const green10 = Color(0x1A1FAF6E);
  static const green12 = Color(0x1F1FAF6E);
  static const green22 = Color(0x381FAF6E);
  static const green30 = Color(0x4D1FAF6E);
  static const green8 = Color(0x141FAF6E);
  static const green80 = Color(0xCC1FAF6E);
  static const indigo = Color(0xFF6B5CFF);
  static const ink = Color(0xFF0E141B);
  static const lilac = Color(0xFFC5A0FF);
  static const midnight = Color(0xFF1B2754);
  static const midnight80 = Color(0xCC1B2754);
  static const mint = Color(0xFF9DE6CB);
  static const navy = Color(0xFF0A1426);
  static const orange = Color(0xFFD97706);
  static const orange12 = Color(0x1FD97706);
  static const orange14 = Color(0x24D97706);
  static const peach = Color(0xFFFFB089);
  static const periwinkle = Color(0xFF9DBEFF);
  static const pink = Color(0xFFEC4899);
  static const pink10 = Color(0x1AEC4899);
  static const red = Color(0xFFFF4D4D);
  static const red12 = Color(0x1FFF4D4D);
  static const red14 = Color(0x24FF4D4D);
  static const red18 = Color(0x2EFF4D4D);
  static const red20 = Color(0x33FF4D4D);
  static const salmon = Color(0xFFFF6E54);
  static const sky = Color(0xFFA0C4FF);
  static const slate4 = Color(0x0A0F1720);
  static const slate5 = Color(0x0D0F1720);
  static const slate55 = Color(0x8C0F1720);
  static const transparent = Color(0x00000000);
  static const violet = Color(0xFF7C3AED);
  static const violet10 = Color(0x1A7C3AED);
  static const white = Color(0xFFFFFFFF);
  static const white10 = Color(0x1AFFFFFF);
  static const white12 = Color(0x1FFFFFFF);
  static const white16 = Color(0x29FFFFFF);
  static const white18 = Color(0x2EFFFFFF);
  static const white20 = Color(0x33FFFFFF);
  static const white22 = Color(0x38FFFFFF);
  static const white25 = Color(0x40FFFFFF);
  static const white35 = Color(0x59FFFFFF);
  static const white40 = Color(0x66FFFFFF);
  static const white45 = Color(0x73FFFFFF);
  static const white6 = Color(0x0FFFFFFF);
  static const white60 = Color(0x99FFFFFF);
  static const white70 = Color(0xB3FFFFFF);
  static const white78 = Color(0xC7FFFFFF);
  static const white8 = Color(0x14FFFFFF);
  static const white80 = Color(0xCCFFFFFF);
  static const white85 = Color(0xD9FFFFFF);
  static const white90 = Color(0xE6FFFFFF);
  static const white92 = Color(0xEBFFFFFF);

  // Repeated illustration / status tints (2.26, 2026-10-13).
  static const blueClear = Color(0x002D6FF7);
  static const orange700 = Color(0xFFC2410C);
  static const gold = Color(0xFFFFB800);
  static const navyShade20 = Color(0x331A2540);
  static const gray230 = Color(0xFFE6E6E6);
  static const red600 = Color(0xFFE03B3B);
  static const purple600 = Color(0xFF9333EA);
  static const lime600 = Color(0xFF65A30D);
  static const rose200 = Color(0xFFFFC2D1);
  static const red300 = Color(0xFFFF8888);
  static const callGreen = Color(0xFF52E0AA);

  // Tech-debt 2.26 — one-off tints moved out of screens (same values;
  // names say the colour, the screen gives the meaning).
  static const art000000a1A = Color(0x1A000000);
  static const art000000a2E = Color(0x2E000000);
  static const art000000a38 = Color(0x38000000);
  static const art000000a40 = Color(0x40000000);
  static const art000000a57 = Color(0x57000000);
  static const art000000a73 = Color(0x73000000);
  static const art000000aB3 = Color(0xB3000000);
  static const art000000aCC = Color(0xCC000000);
  static const art050A11 = Color(0xFF050A11);
  static const art050B17 = Color(0xFF050B17);
  static const art06090E = Color(0xFF06090E);
  static const art06112D = Color(0xFF06112D);
  static const art0B1016 = Color(0xFF0B1016);
  static const art0E141BaEB = Color(0xEB0E141B);
  static const art0E8C5F = Color(0xFF0E8C5F);
  static const art0F1720a0F = Color(0x0F0F1720);
  static const art0F1720a1A = Color(0x1A0F1720);
  static const art0F1720a40 = Color(0x400F1720);
  static const art0F1720a4D = Color(0x4D0F1720);
  static const art0F1720a73 = Color(0x730F1720);
  static const art0F1720aB8 = Color(0xB80F1720);
  static const art0F1F3D = Color(0xFF0F1F3D);
  static const art10B981a24 = Color(0x2410B981);
  static const art14191F = Color(0xFF14191F);
  static const art141B25aDC = Color(0xDC141B25);
  static const art1A2330 = Color(0xFF1A2330);
  static const art1A2330a33 = Color(0x331A2330);
  static const art1A2540a14 = Color(0x141A2540);
  static const art1A2540a4D = Color(0x4D1A2540);
  static const art1A2540a66 = Color(0x661A2540);
  static const art1B2754aE6 = Color(0xE61B2754);
  static const art1C1E24 = Color(0xFF1C1E24);
  static const art1C5BE0 = Color(0xFF1C5BE0);
  static const art1E40AF = Color(0xFF1E40AF);
  static const art1F1F22 = Color(0xFF1F1F22);
  static const art1FAF6Ea33 = Color(0x331FAF6E);
  static const art20262E = Color(0xFF20262E);
  static const art222222aCC = Color(0xCC222222);
  static const art2A1B45 = Color(0xFF2A1B45);
  static const art2A2D35 = Color(0xFF2A2D35);
  static const art2BC58A = Color(0xFF2BC58A);
  static const art2D2640 = Color(0xFF2D2640);
  static const art2D6FF7a24 = Color(0x242D6FF7);
  static const art2D6FF7a38 = Color(0x382D6FF7);
  static const art2D6FF7a40 = Color(0x402D6FF7);
  static const art2D6FF7a47 = Color(0x472D6FF7);
  static const art2D6FF7aCC = Color(0xCC2D6FF7);
  static const art2D6FF7aD9 = Color(0xD92D6FF7);
  static const art4889FF = Color(0xFF4889FF);
  static const art5DE5A8 = Color(0xFF5DE5A8);
  static const art6366F1 = Color(0xFF6366F1);
  static const art65A30Da1F = Color(0x1F65A30D);
  static const art7C3AEDa00 = Color(0x007C3AED);
  static const art7C3AEDa24 = Color(0x247C3AED);
  static const art7C3AEDa29 = Color(0x297C3AED);
  static const art9333EAa1A = Color(0x1A9333EA);
  static const artA7C5EB = Color(0xFFA7C5EB);
  static const artA855F7 = Color(0xFFA855F7);
  static const artA8A8AB = Color(0xFFA8A8AB);
  static const artA8E6FF = Color(0xFFA8E6FF);
  static const artB5E2A1 = Color(0xFFB5E2A1);
  static const artB91C1C = Color(0xFFB91C1C);
  static const artD4B8FF = Color(0xFFD4B8FF);
  static const artD97706a14 = Color(0x14D97706);
  static const artD97706a3D = Color(0x3DD97706);
  static const artE04A4Aa4D = Color(0x4DE04A4A);
  static const artE0683Ba1F = Color(0x1FE0683B);
  static const artE0B43B = Color(0xFFE0B43B);
  static const artE0B43Ba1A = Color(0x1AE0B43B);
  static const artE5484Da22 = Color(0x22E5484D);
  static const artE63946 = Color(0xFFE63946);
  static const artE8A317 = Color(0xFFE8A317);
  static const artF59E0Ba29 = Color(0x29F59E0B);
  static const artFF4D4Da1A = Color(0x1AFF4D4D);
  static const artFF4D4Da38 = Color(0x38FF4D4D);
  static const artFF4D4Da52 = Color(0x52FF4D4D);
  static const artFF6B6B = Color(0xFFFF6B6B);
  static const artFF6B9D = Color(0xFFFF6B9D);
  static const artFFA07A = Color(0xFFFFA07A);
  static const artFFB020a1F = Color(0x1FFFB020);
  static const artFFB4B4 = Color(0xFFFFB4B4);
  static const artFFB800a24 = Color(0x24FFB800);
  static const artFFB800a2E = Color(0x2EFFB800);
  static const artFFB800a33 = Color(0x33FFB800);
  static const artFFB800a66 = Color(0x66FFB800);
  static const artFFB800a73 = Color(0x73FFB800);
  static const artFFCFA5 = Color(0xFFFFCFA5);
  static const artFFE08A = Color(0xFFFFE08A);
  static const artFFFFFFa00 = Color(0x00FFFFFF);
  static const artFFFFFFa24 = Color(0x24FFFFFF);
  static const artFFFFFFa4D = Color(0x4DFFFFFF);
  static const artFFFFFFa80 = Color(0x80FFFFFF);
  static const artFFFFFFa8C = Color(0x8CFFFFFF);
  static const artFFFFFFaA5 = Color(0xA5FFFFFF);
}
