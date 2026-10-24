# DeepSeekMeter — Project Notes

A macOS menu bar HUD showing DeepSeek account balance and token throughput. Swift 6 toolchain, SwiftPM, AppKit + SwiftUI. No Xcode project.

## Commands

```bash
swift build                                  # debug build
swift test                                   # 23 XCTest cases
./build.sh                                   # universal .app bundle
./build.sh --native                          # faster, current arch only
swift run DeepSeekMeter --snapshot           # regenerate docs/screenshots/*.png
swift Scripts/make-icon.swift                # regenerate icon (writes docs/icon.png + Resources/AppIcon.icns)
```

## Layout

- `Sources/DeepSeekMeter/App.swift` — `MenuBarExtra`, `WidgetPanel` (NSPanel), `HoverHostingView`, `PanelController` geometry, `Snapshot` offscreen renderer.
- `Sources/DeepSeekMeter/Data.swift` — `TranscriptScanner` (incremental JSONL reader), `DeepSeek` client, `UsageStore` (@Observable, MainActor).
- `Sources/DeepSeekMeter/Models.swift` — `Balance`, `DayRecord`, `Thresholds`, `Level`, `Clock`, `Fmt`.
- `Sources/DeepSeekMeter/Design.swift` — palette, `GlassCard`, `Orb`, `VBars`, `GaugeBar`, typography helpers.
- `Sources/DeepSeekMeter/Views.swift` — the three states: idle pill, hover card, expanded report.
- `Tests/DeepSeekMeterTests/MeterTests.swift` — all tests.

## Invariants

- Three states only: `.idle` (116×30), `.hover` (200×192), `.expanded` (292×500). Sizes live in `PanelController.Layout`.
- The panel is `.nonactivatingPanel`, `canBecomeKey == false`, level `.statusBar`, joined to all Spaces. It must never steal focus.
- Tap vs drag is decided in `WidgetPanel.sendEvent` with a 3 pt threshold; expanded mode sets `handlesPointer = false` so SwiftUI gets clicks.
- `RootView` sizes itself to the panel; changing a layout without changing `Layout.size` will clip.
- Transcript timestamps are UTC, buckets are **local** via `Clock`. Tests must compare through `Clock`, never hard-coded strings.
- `UsageStore.save()` is deliberately conditional (`ingested > 0 || prune()`). Do not make it unconditional — the ticker runs every 4 s.
- Balance deltas are only attributed to today when readings are <15 minutes apart (`lastBalanceAt`).

## Rules

- Never print, commit or hardcode `ANTHROPIC_AUTH_TOKEN`. It is read from env or `~/.claude/settings.json` at runtime only.
- No force unwraps in new code. No new dependencies without asking.
- Screenshots must be generated with `demoStore()` data, never a live balance.
- `.claudeignore` and `.gitignore` are separate files with overlapping rules; leave `.claudeignore` alone.
