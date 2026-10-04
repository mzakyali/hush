# Contributing to Hush

Thanks for your interest. Hush started as a personal project, so scope is
deliberately narrow — the best contributions are bug fixes, correctness
improvements, and work that fits the product spec
(`docs/specs/hush-v1.md`). For anything larger, open an issue first so we
can talk it through.

## Setup

- macOS 26+, Apple Silicon, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`), and once: `xcodebuild -downloadComponent MetalToolchain`.
- Build the app: `xcodegen generate && xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation build`

## Commands

- Logic tests: `swift test --package-path Packages/HushKit`
- Re-render UI snapshots: `--render-snapshots <dir>` (Debug builds only —
  resolve the built binary via `xcodebuild … -configuration Debug
  -showBuildSettings`, `CONFIGURATION_BUILD_DIR`; see README → Development)
- Install + launch: `scripts/install.sh`
- Logs: `log show --info --predicate 'subsystem == "com.local.hush"'`

## Project rules

These are invariants — PRs that break them will be asked to change:

- Swift 6 strict concurrency. Engines live behind protocols; tests use
  fakes, not real engines.
- No test may download models. Integration tests that need real models must
  be gated on `HUSH_INTEGRATION=1`.
- No network calls except explicit model download.
- No transcript text in logs — timings, counts, and states only.
- Privacy invariants: never read secure text fields; all data stays under
  `~/Library/Application Support/Hush/` (tests inject a temp dir via
  `AppPaths`).

## UI changes

Follow `DESIGN.md` (tokens, components, motion budget) and re-render the
snapshots in `spike/ui-snapshots/` so visual regressions are reviewable.

## AI-agent contributors

`AGENTS.md` contains the commands and layout agents (and humans) need —
keep it accurate when you change the build or layout.

## Pull requests

- Keep diffs focused; explain what changed and how you verified it.
- Run `swift test --package-path Packages/HushKit` and an app build.
- If you touched the UI, re-render snapshots.
