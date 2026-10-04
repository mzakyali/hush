# Hush

Local voice dictation app for macOS. See `docs/specs/hush-v1.md` and `docs/plans/2026-10-01-hush-v1.md`.

## Commands

- Logic tests: `swift test --package-path Packages/HushKit`
- App build: `xcodegen generate && xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Debug -destination 'platform=macOS' build`
  - Headless builds need `-skipPackagePluginValidation -skipMacroValidation` (mlx-swift's CudaBuild plugin prompts for trust otherwise).
  - Xcode 27 needs the Metal toolchain component: `xcodebuild -downloadComponent MetalToolchain`.
- Install + launch: `scripts/install.sh` (xcodegen → Release build → replace `/Applications/Hush.app` → unregister the DerivedData copy from LaunchServices → open).
  - Signing is **ad-hoc** (`CODE_SIGN_IDENTITY="-"`): `security find-identity -v -p codesigning` finds 0 identities on this machine. Ad-hoc signatures differ per build, so Accessibility / Input Monitoring / Microphone grants must be re-approved after every install. If an "Apple Development" identity ever exists, set `CODE_SIGN_IDENTITY` to it in `project.yml` — stable signatures keep permission grants across rebuilds.
  - The first model load per app triggers a one-time Core ML/E5 compile (can take 10+ min, `ANECompilerService` spins); the result is cached in `~/Library/Caches/com.local.hush/` and survives rebuilds — subsequent loads take ~4 s. Watch `log show --info --predicate 'subsystem == "com.local.hush"'` for `whisper →`/`cleanup →` timings.
  - Models load offline-first: when files exist under `models/`, launch makes zero hub requests (verified: `lsof -iTCP` empty).

## Layout

- `project.yml` — XcodeGen spec (regenerate the project after changing it; `Hush.xcodeproj` is git-ignored).
- `App/` — app target sources (SwiftUI + AppKit), `App/HushIcon.icon` (Icon Composer doc — app icon, compiled by actool via `ASSETCATALOG_COMPILER_APPICON_NAME`), `App/Assets.xcassets/MenuBarIcon` (template menu-bar icon; regenerate PNGs with `swift scripts/render-icon.swift`).
- `Packages/HushKit/` — all logic, one library target per module: `HushCore` (shared types, pipeline), `HotkeyService`, `AudioCapture`, `Transcription`, `Cleanup`, `Dictionary`, `Insertion`, `EditWatcher`, `Media`, `Store`. Each module has a test target.
- `docs/brand/` — brand assets (mark/app-icon SVGs, banners, `brand-guidelines.md`); regenerate PNGs with `swift scripts/render-brand.swift` from the repo root.

## Rules

- Swift 6 strict concurrency. Engines behind protocols; tests use fakes.
- No test may download models except opt-in integration tests gated on `HUSH_INTEGRATION=1`.
- No network calls except explicit model download.
- Data dir: `~/Library/Application Support/Hush/` (`hush.sqlite`, `audio/`, `models/`). Tests inject a temp dir via `AppPaths`.
