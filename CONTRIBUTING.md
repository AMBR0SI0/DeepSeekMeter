# Contributing

Thanks for looking. This is a small app on purpose — the fastest way to get a change merged is to keep it that way.

## Before you start

- **Bug reports** are the most valuable thing you can send. Include your macOS version, whether you are on Apple silicon or Intel, and what the pill was showing when it went wrong. If the issue is about the numbers, say which Claude Code setup produced them (DeepSeek via `ANTHROPIC_BASE_URL`, OpenRouter, something else).
- **Feature ideas** — open an issue first. The widget has three states and one screen; features that need a fourth state or a settings window will probably be declined, not because they are bad but because the HUD stops being a HUD.

## Development setup

```bash
git clone https://github.com/AMBR0SI0/token-meter.git
cd token-meter
swift build
swift test
```

Requires macOS 14+, Xcode 16 or newer (Swift 6 toolchain), and the Command Line Tools. The package deliberately builds in Swift 5 language mode; do not "fix" that without a reason.

## Pull requests

1. Branch from `main`.
2. Keep the diff focused: one concern per PR, no drive-by reformatting.
3. Run `swift build` and `swift test`. Both must pass.
4. If you changed a view, run `swift run TokenMeter --snapshot` and include the regenerated PNGs — screenshots in `docs/screenshots/` use deterministic demo data, so they are diffable.
5. Write a commit message that says why, not just what.

## Adding a provider

Providers are data, not code paths. A new preset is one `static let` in `Provider.swift` (name, key variable, balance endpoint, JSON paths) plus, if the provider publishes a price list, a `Pricing` preset in `Pricing.swift` and a detection branch in `Presets.detect`. Add a test to `ProviderTests` for the detection and to `PricingTests` for the rates. Anything that cannot be expressed as a preset is already configurable through `config.json`, so a code change should be rare.

## House rules

- No secrets, tokens or personal identifiers in code, tests, fixtures or screenshots. The snapshot demo data exists so real balances never end up in the repo.
- No force unwraps in new Swift code. Handle the failure, or use a guard with a clear fallback.
- No third-party dependencies beyond SwiftUI, AppKit, Swift Charts, Foundation and [Pow](https://github.com/EmergeTools/Pow). Ask before adding one.
- Match the surrounding style: small types, small functions, comments only where the reason is not obvious from the code.
- The HUD must never take keyboard focus, and must survive display changes, Spaces and full-screen apps. Test those paths if you touch `PanelController`.

## Releasing (maintainer)

1. Bump `CFBundleShortVersionString` in `build.sh`.
2. `./build.sh` and confirm `lipo -archs TokenMeter.app/Contents/MacOS/TokenMeter` prints `x86_64 arm64`.
3. Regenerate screenshots and commit everything.
4. Tag: `git tag v1.0.0 && git push --tags`.
