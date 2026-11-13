# Launch Screen Assets

The Sinhron mark (`lib/widgets/sinhron_mark.dart`, 96 pt) on the launch
background (`LaunchBackground` colorset = `DsTokens.light/dark.bg`), light and
dark variants at 1×/2×/3×. Re-render them from the widget if the mark changes
(App Store item 7, 2026-10-16: a test that pumps `SinhronMark(size: 96)` in a
`RepaintBoundary` and saves `toImage(pixelRatio: 1/2/3)` as PNG).
