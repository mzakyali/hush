# Hush — Handoff

Local, offline-first voice dictation app for macOS (Apple Silicon). A personal-use clone of Wispr Flow. Reads mic input via a global hotkey, transcribes + cleans up locally, and inserts the result into the focused app (clipboard fallback).

**Read first:** `AGENTS.md` (rules + commands), `docs/specs/hush-v1.md` (product spec, settled), `docs/plans/2026-10-01-hush-v1.md` (task graph T1–T16), `DESIGN.md` (visual spec), this file.

**Owner/device context:** single user, personal MacBook Pro (16 GB), macOS 26 (Tahoe). Dark-only UI. English + Indonesian dictation with intra-utterance code-switching is a hard requirement.

## Repo layout

- `App/` — SwiftUI/AppKit app target (AppModel is the single observable model; windows are `NSPanel`s/`NSHostingView`s, not SwiftUI windows).
  - `EdgePanelController`/`EdgePanelView` — left/right-edge icon rail (see DESIGN.md §edge panel).
  - `OverlayWindowController`/`OverlayView` — bottom recording pill, dictation-only.
  - `MenuBarView`, `MainWindow*` (Home/History/Dictionary/Styles/Settings pages), `SnapshotRunner` (renders snapshot states for review, `-snapshot` launch flag).
- `Packages/HushKit/` — all logic, one library + one test target per module:
  `HushCore` (pipeline, types, WordDiff, AppPaths), `HotkeyService`, `AudioCapture` (recorder, sample-rate converter, devices, MicSelector/MicStore/DeviceListMonitor, m4a encoder), `Transcription` (WhisperTranscriber), `Cleanup` (MLXCleaner, CleanupPrompt, CleanupGuard), `Dictionary` (EMPTY — Placeholder.swift only), `Insertion` (Inserter, InsertionPolicy, PasteboardSnapshot), `EditWatcher` (EMPTY), `Media` (EMPTY), `Store` (DictationStore, GRDB sqlite).
- `scripts/` — `install.sh` (xcodegen → Release build → replace `/Applications/Hush.app` → launch), `render-icon.swift`.
- `spike/` — experiments: `cleanup-bench-results.md`, `ui-snapshots/` (all UI states rendered as PNGs — regenerate after visual changes), `icon-preview/`, `samples/` (user audio).

## Commands

```bash
swift test --package-path Packages/HushKit          # ~91 tests, all green as of 2026-10-02
xcodegen generate                                    # after project.yml changes
scripts/install.sh                                   # build + replace /Applications/Hush.app + launch
log show --info --predicate 'subsystem == "com.local.hush"'   # stage timings, model loads
```

Headless xcodebuild needs `-skipPackagePluginValidation -skipMacroValidation`. Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain` once.

## What's implemented (verified by tests; user-verified unless noted)

**Core loop (T2–T7):** hold-Fn and double-tap-⌥ hotkeys (HotkeyStateMachine + CGEventTap, Input Monitoring perm); Esc cancels (nothing saved/pasted); record via AVAudioEngine → 16 kHz mono; WhisperKit transcription → replacements → Qwen cleanup → insert into app focused at stop; clipboard fallback + notification when no text field; Slack/Discord paste path (no AX value needed); pasteboard snapshot/restore.

**Bilingual ASR (post-plan fix):** `WhisperTranscriber.transcribe` decodes twice — forced `en` and forced `id` (no auto-detect) — and picks the higher mean `segments.avgLogprob` (`static func pick`; empty text → −∞; tie → en; strips wrapping quotes). Measured 19/19 correct on the user's real clips + Indonesian TTS clips. `Transcript.languageScores` carries both. Cost: ASR latency ~doubles (~1.5–2.5 s typical). Opt-in harness: `HUSH_INTEGRATION=1 HUSH_LANG_DIR=<dir of .m4a> swift test --filter languageExperiment` (file: `Tests/TranscriptionTests/LanguageExperimentTests.swift` — keep as opt-in or delete; it reads saved user audio).

**Cleanup:** `MLXCleaner` runs Qwen3-4B-Instruct-2507-4bit (fallback gemma-3-4b), system-prompt KV cache, unloads after 10 min idle, `RunStats` prompt/gen timings. `GuardedCleaner` validates output (word-overlap check → falls back to raw rather than drop words — user-facing safety rule), plus a **fast path**: `CleanupGuard.isClean` (no filler/repeated n-gram/correction cue, non-formal style) skips the LLM entirely. Logging: `cleanup → skipped` / `llm prompt N gen M`.

**Cleanup disfluencies (2026-10-03):** Replayed both reported “the… sorry… the…” transcripts with the cached Qwen model. Added explicit abandoned-start instructions, sentence-case guidance, and examples preserving the full message and trailing question. Coverage exempts an explicitly paused repeated 1–4-word start around a correction cue; genuine apologies and ordinary repetitions still count as content. See `docs/checks/2026-10-03-cleanup-disfluencies.md`. The “Both” screenshot was a separate recording continuing earlier text: cleanup has no preceding-field context, so its sentence-start capitalization is expected, and continuation handling was not added.

**Insertion:** `InsertionPolicy.leadingSeparator` prepends a space iff the AX-read char before the caret is non-whitespace/non-opening and the text doesn't start with closing punctuation; fails safe (no space) when AX unreadable (Electron, secure fields). `InsertionResult.pasted` carries `insertedLength` for future paste-raw replacement.

**History/Store:** GRDB `dictations` table (camelCase columns: `createdAt`, `durationSec`, `appBundleID`, `appName`, `rawText`, `cleanedText`, `style`, `cleanupFallback`, `audioPath`), m4a audio in `audio/`, 30-day retention (`enforceRetention`), `stats()`, `wordsPerDay()`, search. History page: grouped by day, search, expanded rows show audio player, word-level `WordDiff` (`.changed` op coalesces case/punct swaps), `NO CLEANUP NEEDED`/`CLEANUP FELL BACK` chip when raw==cleaned, Copy raw only when they differ.

**UI:** dark-only; SF for UI, Geist Mono for labels/numbers, Instrument Serif for the big stat headline; orange `#FF5B2E` accent (`Theme.Color.signal`). Sidebar pages Home (stats + 12-week heatmap + perms/models), History, Dictionary (placeholder), Styles (placeholder), Settings. **Bottom pill**: 148×32 dot-wave (travelling sine, level-driven amplitude, orange hot centre, wave-settle→check on done). **Edge side panel**: 56×260 icon-only resting rail (status ring, mic device menu, activity, record + gear), hover → 240×424 details (7-day dot strip, WPM/TIME SAVED/STREAK/DICTATIONS). Drag the top handle vertically or across the screen; release always glides to the nearest left/right edge with concave fillets (floating only during drag); edge/vertical position persist, right-click menu incl. Mic submenu, Hide, Restart (relaunch), Quit. Settings toggles: floating-bar→"Show side panel" (default ON), "Show in menu bar" (`@AppStorage` for `isInserted` — binding an ObservedObject there livelocked once, don't regress), "Show in Dock", with last-surface guard.

**Motion:** side-panel hover/snap glide (~420ms, geometry and click routing synchronized per frame), moving sidebar selection, page slide/crossfade, rolling statistics, interpolated activity dots, history expansion/hover/copy-check feedback, and control press/hover response. `HushReducedMotion` reads the OS preference and permits preview overrides; reduces spatial/symbol motion to fades and immediate snapping. No idle frame timer. Recording pill visual design is preserved.

**Recording UI regression (2026-10-02, fixed and user-verified):** the animated icon rail caused live UI stalls after Fn release, despite its original synthetic checks passing. In-process traces show the tap emitting holdEnd correctly, followed by delayed UI/control consumption; sampling found RenderBox/Core Animation synchronization and the pulsing symbol renderer. Hiding the panel cleared the backlog. Removed repeating pulse and SF Symbol replacement effects from the rail status icon; it now fades briefly between steady icons. The build, logic suite, and eight window probes pass. User verified two consecutive recordings with another app focused and the panel enabled: both stop promptly on Fn release, completion clears without clicking, and the second run works. Both live releases reached UI processing within about 1ms in the trace. Diagnostic logs contain only Fn/actions/UI states, never typed text or transcripts. See `docs/checks/2026-10-02-fn-release.md`.

**Permissions:** per-permission Allow buttons (Microphone/Accessibility/Input Monitoring) on Home + Settings, 1 s polling, `Restart Hush` when taps can't start. Ad-hoc signing ⇒ grants die every reinstall — **unresolved, see Open Decisions**.

**Mic priority (§4a/T12):** `MicSelector.resolve`/`merge` pure fns; `MicStore` persists ordered UIDs + pin in UserDefaults (pin clears on disconnect); `DeviceListMonitor` CoreAudio listener; `hooks.deviceUIDs()` yields priority candidates → nil = system default; switch only between recordings; start-failure → next candidate + `.deviceFallback` update; Settings Microphone section (Automatic picker, drag-reorder list, DISCONNECTED labels, AirPods footnote); side panel header shows active mic.

**Diagnostics:** per-dictation info log `pipeline: audio X.XXs | asr X.XXs (en lp, id lp → lang) | cleanup X.XXs (...) | insert X.XXs | total X.XXs` — no text in logs.

## Not implemented yet (plan refs)

- **T8 Dictionary** — module is a placeholder. Terms + deterministic replacements + LLM `terms` prompt hookup; spec §5.
- **T9 EditWatcher / learn-from-edits** — placeholder. Watch pasted field via AX for ~60 s, word-level fixes → suggestion (2-occurrence auto-add), skip secure fields; spec §6.
- **T10 per-app styles** — `PipelineHooks.style` still returns `.default` always (pipeline L15 comment). Bundle-ID mapping defaults in plan line 151; Styles page is a placeholder.
- **T11 paste-raw ⌃⌥Z** — hotkey emits `.pasteRaw` (HotkeyStateMachine:220) but `DictationPipeline` ignores it (idle comment L140). Plumbing ready: `lastInsertion`, `insertedLength` (includes prepended space — replacement must account for it).
- **T13 Media auto-pause** — placeholder module.
- **Settings misc:** retention-days picker, typing-WPM, launch-at-login (`SMAppService`), hotkey reassignment UI.
- **Onboarding flow** (plan T15): first-run Fn-key instruction, model download progress screens.
- **Stats aggregates** currently derive from `dictations` rows — spec wants day-level aggregates surviving retention (deleting a dictation will shrink stats; check `DictationStats` sourcing before shipping retention).

## Gotchas / past bugs (don't reintroduce)

1. **Ad-hoc re-sign breaks TCC grants every build** — also pollutes Privacy settings with dead "Hush" entries; the Allow buttons reset stale TCC state. See Open Decisions.
2. `SampleRateConverter` input block must return `.noDataNow` after the first buffer, never `.endOfStream` (was truncating every recording to ~0.1 s → "no speech" + flat waveform).
3. `AsyncStream` consumers: cancelling the pump task terminates the stream — that's why `makeLevelStream()`/`makeChunkStream()` exist (fresh stream per recording; levels `.bufferingNewest(16)`, chunks `.unbounded`, nil continuation ⇒ no buffering).
4. WhisperKit `detectLangauge` langProbs are useless (top lang only); forced-decade avgLogprob comparison is the mechanism — keep it.
5. WhisperKit decodes are nondeterministic across calls (temperature fallback). Selection is valid w.r.t. that run's own scores.
6. Partials pump intentionally removed (unused, competed with final decode); `Transcriber.partials` API kept.
7. `MenuBarExtra(isInserted:)` must bind `@AppStorage`, not `@ObservedObject` (livelock).
8. Panels are `.nonactivatingPanel`; focus must never leave the target app. Side panel uses a card-sized window + local/global pointer monitors to set `ignoresMouseEvents` outside `SidePanelShape`. A view returning nil from `hitTest` alone still lets the window block the app underneath. Window-server regression: run the built executable with `--render-snapshots <dir> --verify-side-panel`. Recording pill still uses `pillHitRect`. Verify focus with a real click after panel changes.
9. Overlay pill is user-approved: don't restyle it.
10. `recorder.chunks` unconsumed during recording = fine now (nil continuation); don't leave a consumer buffering forever.
11. Snapshot runner: `SnapshotRunner.swift` + `spike/ui-snapshots/` — pixel-verify visual changes; `screencapture` is unavailable to shells (no Screen Recording perm).
12. Avoid native SF Symbol pulse/replacement effects in the side-panel status icon. A physical background-app dictation test is required after panel animation changes; snapshots and active-app scheduling probes missed the stalled recording/checkmark behavior.

## Models / data

- `~/Library/Application Support/Hush/`: `hush.sqlite`, `audio/*.m4a`, `models/` (`openai_whisper-large-v3-v20240930_turbo_632MB` + tokenizer; `mlx-community/Qwen3-4B-Instruct-2507-4bit`). Offline-first: zero hub requests when files exist (verify `lsof -iTCP`).
- First Whisper load compiles CoreML once (10+ min, ANECompilerService), cached in `~/Library/Caches/com.local.hush/`; then ~4 s. Cleanup ~1.3 s. They load concurrently.
- HuggingFace cache was cleaned 2026-10-01; Gemma + Qwen-1.7B deleted (Gemma would redownload only if Qwen fails to load — it's the fallback).
- Mic input is quiet (peak 0.04–0.10); level meter maps −55…−15 dBFS → 0…1 + attack/release smoothing in `AppModel.pushLevel`.

## User decisions still open / awaiting feedback

1. **Signing (biggest UX pain):** choose free Apple ID in Xcode Accounts vs. agent-created self-signed cert in login keychain (one password prompt). Either → one final re-grant, then permissions survive rebuilds. Asked twice; unanswered.
2. **Live-testing:** user confirmed the previous side-panel top-handle dragging and clicks outside work (2026-10-02). The refined icon rail passed nearest-edge snap, expanded drag continuity, Reduce Motion, and click-through probes in Debug and the installed Release build; its real microphone menu was verified. Repeat the physical drag check on this version. Pending: panel focus-preservation across apps, physical multi-display dragging, mic hot-plug + failure fallback, smart-space in real apps, real Indonesian + mixed dictation under dual-decode, waveform on every recording. See `docs/checks/2026-10-02-icon-rail-motion.md` and the earlier `docs/checks/2026-10-02-side-panel.md`.
3. `LanguageExperimentTests.swift` is diagnostic scaffolding — keep as opt-in or delete before any commit.
4. Nothing is committed; repo may not even be `git init`'d per plan T1 status — check `git status` first.

## Working conventions

- Delegation: substantive implementation via subagent/sidekick handoffs; owner reviews snapshots + diffs. Previous rounds used `/tmp/hush-lang` + `/tmp/hush-lang-id` recordings for ASR experiments (may still exist).
- Verify: tests green → `install.sh` → confirm models ready + window/panel on screen via CGWindowList → leave app running.
- Style: compact idiomatic Swift 6, no gratuitous comments, engines behind protocols, tests with fakes, `.public` privacy on logs, no transcript text in logs.
- Never: commits/pushes without explicit ask; destructive ops without confirmation; network calls beyond model download.
