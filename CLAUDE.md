# TokenMeter — Project Notes

A macOS menu bar HUD showing an LLM endpoint's remaining balance, token throughput and estimated spend. Provider-agnostic: usage comes from Claude Code transcripts, balance and prices come from a preset plus `config.json`. Swift 6 toolchain, SwiftPM, AppKit + SwiftUI. No Xcode project.

## Commands

```bash
swift build                                  # debug build
swift test                                   # 47 XCTest cases
./build.sh                                   # universal .app bundle
./build.sh --native                          # faster, current arch only
swift run TokenMeter --snapshot              # regenerate docs/screenshots/*.png
swift Scripts/make-icon.swift                # regenerate icon (writes docs/icon.png + Resources/AppIcon.icns)
swift Scripts/make-logo.swift                # regenerate the README logo from docs/icon.png
```

## Layout

- `Sources/TokenMeter/App.swift` — `MenuBarExtra`, `WidgetPanel` (NSPanel), `PanelController` geometry, menu + `Configuration.open()`, `Snapshot` offscreen renderer.
- `Sources/TokenMeter/Data.swift` — `TranscriptScanner` (incremental JSONL reader), `UsageStore` (@Observable, MainActor), config loading, persistence and migration.
- `Sources/TokenMeter/Provider.swift` — `JSONPath`, `KeyRef`, `BalanceSpec`, `Provider`, presets, `Presets.detect`, `BalanceClient`.
- `Sources/TokenMeter/Pricing.swift` — `ModelPrice`, `PriceSchedule`, `Pricing`, cost math, override merging.
- `Sources/TokenMeter/Models.swift` — `Balance`, `DayRecord`, `Thresholds`, `Level`, `Clock`, `Fmt`.
- `Sources/TokenMeter/Design.swift` — palette, `GlassCard`, `Orb`, `VBars`, `GaugeBar`, typography helpers.
- `Sources/TokenMeter/Views.swift` — the three states: idle pill, compact card, expanded report.
- `Tests/TokenMeterTests/MeterTests.swift` — all tests.

## Invariants

- Three states only: `.idle` (116×30), `.compact` (200×192), `.expanded` (292×500). No hover tracking. Sizes live in `PanelController.Layout`.
- The panel is `.nonactivatingPanel`, `canBecomeKey == false`, level `.statusBar`, joined to all Spaces. It must never steal focus.
- Tap vs drag is decided in `WidgetPanel.sendEvent` with a 3 pt threshold. `performDrag` must be anchored to the mouse-down event — anchoring to the first dragged event offsets the window on every drag.
- `performDrag` returns *before* the window has moved. The drag finishes on the next `.leftMouseUp`, which is where the edge snap (`reanchor`) runs. Do not snap straight after `performDrag`; the frame is still the old one.
- Clicking is handled by the panel, not by SwiftUI. Do not add a `contentShape`/`onTapGesture` to the card surface: it fires alongside the header buttons, so `−` collapsed to the pill and immediately reopened.
- The compact card grows buttons in its top-right `Layout.compactControls` square; `PanelController.tapped(at:)` ignores clicks there so SwiftUI gets them.
- `RootView` sizes itself to the panel; changing a layout without changing `Layout.size` will clip.
- Transcript timestamps are UTC, buckets are **local** via `Clock`. Tests must compare through `Clock`, never hard-coded strings.
- `UsageStore.save()` is deliberately conditional (`ingested > 0 || prune()`). Do not make it unconditional — the ticker runs every 4 s.
- Balance deltas are only attributed to today when readings are <15 minutes apart (`lastBalanceAt`).
- Usage fields are provider-independent; never branch on `provider.name` outside presets. Balance and pricing are the only provider-specific surfaces.
- `DayRecord.spend` is the price-table estimate; `DayRecord.observed` is balance-delta spend. Keep them separate — an unpriced model must leave `pricedTokens < tokens` rather than silently cost zero.
- `Pricing.merge` overlays config onto the preset: adding one model must not drop the others. With no matching price and no fallback, `cost` returns nil (unpriced), never 0.
- Config is reloadable at runtime (`applyConfig` / `reloadConfiguration`); do not cache it at init.

## Rules

- Never print, commit or hardcode `ANTHROPIC_AUTH_TOKEN`. It is read from env or `~/.claude/settings.json` at runtime only.
- No force unwraps in new code. No new dependencies without asking.
- Screenshots must be generated with `demoStore()` data, never a live balance.
- `.claudeignore` and `.gitignore` are separate files with overlapping rules; leave `.claudeignore` alone.
