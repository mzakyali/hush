# Hush — Handoff

Local, offline-first voice dictation app for macOS (Apple Silicon). A personal-use clone of Wispr Flow. Reads mic input via a global hotkey, transcribes + cleans up locally, and inserts the result into the focused app (clipboard fallback).

**Read first:** `AGENTS.md` (rules + commands), `docs/specs/hush-v1.md` (product spec, settled), `docs/plans/2026-10-01-hush-v1.md` (task graph T1–T16), `DESIGN.md` (visual spec), this file.

**Owner/device context:** single user, personal MacBook Pro 13" M1 (16 GB), macOS 26 (Tahoe), Touch Bar. Dark-only UI. English + Indonesian dictation with intra-utterance code-switching is a hard requirement.

## Repo layout

- `App/` — SwiftUI/AppKit app target (AppModel is the observable model; hot per-frame state lives in `StateFeeds.swift` — RecordingFeed/SidePanelGeometry/PlaybackFeed — not on AppModel; windows are `NSPanel`s/`NSHostingView`s, not SwiftUI windows).
  - `EdgePanelController`/`EdgePanelView` — compact edge rail + expanded card (see DESIGN.md §edge panel).
  - `OverlayWindowController`/`OverlayView` — bottom recording pill, dictation-only.
  - `TouchBarController` + `TouchBarPrivate.h` — Control Strip item + system-modal bars (private DFR API, bridging header in `project.yml`).
  - `MenuBarView`, `MainWindow*` (Home/History/Dictionary/Styles/Settings pages), `SnapshotRunner` (renders snapshot states, `--render-snapshots <dir>` flag).
- `Packages/HushKit/` — all logic, one library + one test target per module:
  `HushCore` (pipeline, types, WordDiff, StyleResolver, AppPaths), `HotkeyService`, `AudioCapture` (recorder, config-change restart, sample-rate converter, devices, MicSelector/MicStore/DeviceListMonitor, m4a encoder), `Transcription` (WhisperTranscriber), `Cleanup` (MLXCleaner, CleanupPrompt, CleanupGuard), `Dictionary` (ReplacementEngine), `Insertion` (Inserter, InsertionPolicy, PasteRawPolicy, PasteboardSnapshot), `EditWatcher` (AX watch, EditDiff, InsertedSpan), `Media` (EMPTY), `Store` (DictationStore, GRDB sqlite).
- `scripts/` — `install.sh` (xcodegen → Release build → replace `/Applications/Hush.app` → launch), `render-icon.swift`.
- `spike/` — experiments: `cleanup-bench-results.md`, `ui-snapshots/` (all UI states rendered as PNGs — regenerate after visual changes), `icon-preview/`, `samples/` (user audio).

## Commands

```bash
swift test --package-path Packages/HushKit          # ~180 tests, all green as of 2026-10-03
xcodegen generate                                    # after project.yml changes
scripts/install.sh                                   # build + replace /Applications/Hush.app + launch
log show --info --predicate 'subsystem == "com.local.hush"'   # stage timings, model loads
```

Headless xcodebuild needs `-skipPackagePluginValidation -skipMacroValidation`. Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain` once.

Debug-only launch flags: `--render-snapshots <dir>` (+ `--verify-side-panel` for the 12-check panel probe — run it after any panel/geometry change), `--hush-synth-levels` (12 Hz synthetic recording levels for CPU measurement).

## What's implemented (verified by tests; user-verified unless noted)

**Core loop (T2–T7):** hold-Fn and double-tap-⌥ hotkeys (HotkeyStateMachine + CGEventTap, Input Monitoring perm); Esc cancels (nothing saved/pasted); record via AVAudioEngine → 16 kHz mono; WhisperKit transcription → dictionary replacements → Qwen cleanup → replacements again → insert into app focused at stop; clipboard fallback + notification when no text field; AX-opaque apps paste regardless of element info; pasteboard snapshot/restore.

**Bilingual ASR (post-plan fix):** `WhisperTranscriber.transcribe` decodes twice — forced `en` and forced `id` (no auto-detect) — and picks the higher mean `segments.avgLogprob` (`static func pick`; empty text → −∞; tie → en; strips wrapping quotes). Measured 19/19 correct on the user's real clips + Indonesian TTS clips. `Transcript.languageScores` carries both. Cost: ASR latency ~doubles (~1.5–2.5 s typical). Opt-in harness: `HUSH_INTEGRATION=1 HUSH_LANG_DIR=<dir of .m4a> swift test --filter languageExperiment`.

**Cleanup:** `MLXCleaner` runs Qwen3-4B-Instruct-2507-4bit (fallback gemma-3-4b), system-prompt KV cache, unloads after 10 min idle, `RunStats` prompt/gen timings. `GuardedCleaner` validates output (word-overlap check → falls back to raw rather than drop words — user-facing safety rule), plus a **fast path**: `CleanupGuard.isClean` (no filler/repeated n-gram/correction cue, non-formal style) skips the LLM entirely. Logging: `cleanup → skipped` / `llm prompt N gen M`. Disfluency handling: explicit abandoned-start instructions + sentence-case guidance (`docs/checks/2026-10-03-cleanup-disfluencies.md`).

**Dictionary + learn-from-edits (T8/T9/§5/§6):** `ReplacementEngine` — whole-word, case-insensitive, longest-`from`-first, Unicode boundaries, `hitCount` per rule; applied before AND after cleanup; terms + replacement `to`-values feed the Whisper prompt, the cleanup `terms` line, and casing protection. Store: `dictionary_entries` (kind term/replacement, source manual/learned/history) + `suggestions` (pending/accepted/rejected; 1st sighting → pending, 2nd → auto-learned, rejected never resurfaces). Dictionary page: SUGGESTIONS/TERMS/REPLACEMENTS sections, source badges, hit counts, add/delete, Approve/Reject; "N suggestions" row in the expanded panel + menu bar; History expanded rows offer Add-as-term/Add-replacement (`source: history`). `EditWatcher` observes the pasted element (`AXObserver` + 1 s poll fallback; stops on focus loss / 60 s / settle), `InsertedSpan` relocates the span near the paste offset, `EditDiff` emits 1–3→1–3-token substitution candidates (≤30 % changed, no punctuation-only, single-token case changes kept); new paste/recording cancels; never logs text.

**Paste-raw ⌃⌥Z (T11):** keeps the last dictation's raw + the exact inserted string (incl. separator); on ⌃⌥Z re-reads the AX range `[caret−insertedLength, caret)`, replaces with raw through the same paste path if it still matches, else notifies ("Can't replace — text was changed" / "…in this app" / "Nothing to undo"). `PasteRawPolicy.decide` is the pure decision fn; applies the same context adjustment as paste so verification stays exact.

**Continuation casing (D3):** `InsertionPolicy.adjustForContext(text:before:terms:style:)` = leading separator + lowercase-first-char when mid-sentence on the same line: not after `. ! ? …`, no newline, style ≠ minimal, first word not `I`-contraction/all-caps ≥2/camel-case (`iPhone`, `McDonald`)/exact dictionary term — edge punctuation stripped before the checks. Reads ~3 chars before the caret (`AXStringForRange` → `AXValue` fallback); nil context → unchanged. History keeps the unadjusted cleaned text; paste-raw applies the same adjustment.

**Insertion:** `leadingSeparator` prepends a space iff the char before the caret is non-whitespace/non-opening and the text doesn't start with closing punctuation; fails safe (no space) when AX unreadable. `InsertionResult.pasted` carries element + `insertedLength` + end offset for EditWatcher and paste-raw.

**Per-app styles (T10/§3.7):** `StyleResolver.resolve` — override → built-in map (casual: Slack/WhatsApp/Discord/Messages/Telegram; formal: Mail/Outlook; minimal: Xcode/VS Code/Windsurf/Cursor/Terminal/iTerm2/Ghostty) → `.default`; `app_styles` table + CRUD; pipeline resolves from the same captured target it inserts into. Styles page: 4 equal-height explanatory tiles + per-app rows (installed built-ins + overrides + history apps; generic icon when uninstalled), segmented picker, `DEFAULT` badge, reset ↺, Add app….

**History/Store:** GRDB `dictations` table + **`stats_daily` day-level aggregates** (upserted in the same save transaction since v1; v2 backfills missing days; retention/deletes never touch aggregates — stats survive). History page: grouped by day, search, expanded rows show audio player, word-level `WordDiff` (`.changed` op coalesces case/punct swaps), `NO CLEANUP NEEDED`/`CLEANUP FELL BACK` chip, Copy raw, add-to-dictionary actions. Settings → Privacy "Reset statistics" clears `stats_daily` only.

**Mic resilience (A):** `AVAudioEngineConfigurationChange` while recording → remove tap, re-select device UID, re-query format, fresh `SampleRateConverter`, reinstall tap onto the same `CaptureSink` (samples kept); debounced burst + post-restart suppression; `RestartBudget` 5/recording; exhausted/failed restart surfaces via `stop()` — but **salvages ≥0.5 s** of audio instead of discarding; error also reaches the UI handler ("Mic input was interrupted — keeping what was captured").

**Mic priority (§4a/T12):** `MicSelector.resolve`/`merge` pure fns; `MicStore` persists ordered UIDs + pin (pin clears on disconnect); `hooks.deviceUIDs()` yields priority candidates → nil = system default; start-failure → next candidate + `.deviceFallback`. Settings Microphone section + side-panel header.

**UI:** dark-only; SF for UI, Geist Mono for labels/numbers, Instrument Serif headline; orange `#FF5B2E` accent. Sidebar pages Home (stats + 12-week heatmap + perms/models), History, Dictionary, Styles, Settings. **Bottom pill**: 148×32 dot-wave (travelling sine, level-driven, orange hot centre, wave-settle→check). **Edge panel**: 32×112 resting rail (status ring + 24pt record circle; "Sliver when idle" → 6×64 hairline), hover → 240×424 card (7-day dots + weekday letters, stats, mic row, activity, gear, grab handle); whole-rail drag with 4 pt click threshold; release snaps to nearest edge with concave fillets; edge/position persist. **Fixed 288×472 window** — expand/collapse is shape-only animation, `setFrame` only on drag/dock/screen-change; `syncInteraction` hit-tests the visible silhouette (both states) with an early-out when the pointer is far outside. Right-click menu incl. Mic submenu, Hide, Restart, Quit. Settings toggles: "Show side panel" (default ON), "Sliver when idle", "Show in menu bar" (`@AppStorage` for `isInserted` — binding an ObservedObject there livelocked once, don't regress), "Show in Dock" (last-surface guard), "Touch Bar controls" (Touch Bar Macs only).

**Touch Bar (E):** private DFR API — `NSTouchBarItem.addSystemTrayItem` Control Strip button (template `MenuBarIcon`, orange while recording/processing); tap → system-modal idle bar (● Dictate, mic popover, Paste raw, Open Hush); `.recording` auto-presents `[✕ Cancel] [dot wave] [■ Stop]`, `.processing` swaps to wave + PROCESSING label; `DFRSystemModalShowsCloseBoxWhenFrontMost(false)` keeps the Esc region free while recording; removed at quit. All selectors `responds(to:)`-guarded; DFR C fns via `dlopen`/`dlsym`; hardware detected by the `dispdfr` IOKit node. Wave is a plain NSView on a 30 Hz timer — ~8.5 % CPU in the synth-levels harness (vs ~18 % baseline panel+pill).

**Hot-state feed split (A2):** AppModel's `@Published` churn repainted every observing view ~12×/s; `RecordingFeed` (levels/overlay state → pill + Touch Bar), `SidePanelGeometry` (panel frames → EdgePanelView), `PlaybackFeed` (progress → the playing History row) own the hot state. Halved synth-levels CPU (~30 % → ~15 %).

**Motion:** side-panel hover/snap glide (~420 ms), moving sidebar selection, page slide/crossfade, rolling statistics, interpolated activity dots, history expansion/hover feedback, control press/hover. `HushReducedMotion` reads the OS preference + preview overrides; reduces spatial/symbol motion to fades/snaps. Recording pill visual design is preserved (user-approved — don't restyle).

**Recording UI regression (2026-10-02, fixed + user-verified):** the animated icon rail caused live UI stalls after Fn release — removed repeating pulse/SF Symbol replacement effects; the status icon fades between steady icons. Diagnostic logs contain only Fn/actions/UI states, never typed text or transcripts. See `docs/checks/2026-10-02-fn-release.md`.

**Permissions:** per-permission Allow buttons (Microphone/Accessibility/Input Monitoring) on Home + Settings, 1 s polling, `Restart Hush` when taps can't start. Ad-hoc signing ⇒ grants die every reinstall — **unresolved, see Open Decisions**.

**Diagnostics:** per-dictation info log `pipeline: audio X.XXs | asr X.XXs (en lp, id lp → lang) | cleanup X.XXs (...) | insert X.XXs | total X.XXs` — no text in logs.

## Not implemented yet (plan refs)

- **T13 Media auto-pause** — placeholder module.
- **Onboarding flow** (T15): first-run Fn-key instruction, model download progress screens.
- **Settings misc:** retention-days picker (constant now), typing-WPM setting (hardcoded), hotkey reassignment UI. (Launch-at-login exists via `SMAppService` in Settings → General.)

## Gotchas / past bugs (don't reintroduce)

1. **Ad-hoc re-sign breaks TCC grants every build** — also pollutes Privacy settings with dead "Hush" entries; the Allow buttons reset stale TCC state. See Open Decisions.
2. `SampleRateConverter` input block must return `.noDataNow` after the first buffer, never `.endOfStream` (was truncating every recording to ~0.1 s → "no speech" + flat waveform).
3. **Config-change restarts need all three guards:** HAL posts a 5–6-notification burst per event (debounce ~150 ms), our own teardown/restart posts another change (~250 ms suppression window), and churn can loop forever (`RestartBudget` = 5 → error at `stop()`, salvaging ≥8000 samples). Without the suppression window the engine restarts itself to death.
4. `AsyncStream` consumers: cancelling the pump task terminates the stream — that's why `makeLevelStream()`/`makeChunkStream()` exist (fresh stream per recording; nil continuation ⇒ no buffering).
5. WhisperKit `detectLangauge` langProbs are useless (top lang only); forced-decode avgLogprob comparison is the mechanism — keep it. Decodes are nondeterministic across calls.
6. Partials pump intentionally removed (unused, competed with final decode); `Transcriber.partials` API kept.
7. `MenuBarExtra(isInserted:)` must bind `@AppStorage`, not `@ObservedObject` (livelock).
8. **Never put hot state on AppModel** (levels ~12 Hz, panel geometry per frame, playback progress) — it repaints every observing view. Route through `RecordingFeed`/`SidePanelGeometry`/`PlaybackFeed` and observe only where needed. Measured ~2× CPU difference.
9. Panels are `.nonactivatingPanel`; focus must never leave the target app. The panel window is fixed-size; `ignoresMouseEvents` hit-tests the *current visible silhouette* (collapsed or expanded, both during the morph) — and WindowServer needs a **settle delay** after toggling `ignoresMouseEvents` before a click lands (~50 ms; the verification probe waits). A direct `panel.setFrame` does NOT cancel an in-flight `animator().setFrame` — all frame writes go through `setPanelFrame()` (zero-duration animator for instant moves) or a stale animation tick will slam the window back to the previous dock. Re-run `--verify-side-panel` after panel changes.
10. Touch Bar uses private API (`addSystemTrayItem`, `presentSystemModalTouchBar:`, DFRFoundation C fns) — everything is runtime-resolved (`responds(to:)` + `dlopen`/`dlsym`, nothing linked), and the `dispdfr` IOKit node gates hardware presence. Keep every call guarded; degrade silently.
11. `recorder.chunks` unconsumed during recording = fine (nil continuation); don't leave a consumer buffering forever.
12. Snapshot runner: `SnapshotRunner.swift` + `spike/ui-snapshots/` — pixel-verify visual changes; `screencapture` can't see app content (no Screen Recording perm; `-b` Touch Bar captures come back black).
13. Avoid native SF Symbol pulse/replacement effects anywhere near the recording path. A physical background-app dictation test is required after panel animation changes; snapshots and scheduling probes missed the stalled recording/checkmark behavior.

## Models / data

- `~/Library/Application Support/Hush/`: `hush.sqlite`, `audio/*.m4a`, `models/` (`openai_whisper-large-v3-v20240930_turbo_632MB` + tokenizer; `mlx-community/Qwen3-4B-Instruct-2507-4bit`). Offline-first: zero hub requests when files exist (verify `lsof -iTCP`).
- First Whisper load compiles CoreML once (10+ min, ANECompilerService), cached in `~/Library/Caches/com.local.hush/`; then ~4 s. Cleanup ~1.3 s. They load concurrently.
- HuggingFace cache was cleaned 2026-10-01; Gemma + Qwen-1.7B deleted (Gemma would redownload only if Qwen fails to load — it's the fallback).
- Mic input is quiet (peak 0.04–0.10); level meter maps −55…−15 dBFS → 0…1 + attack/release smoothing in `AppModel.pushLevel`.

## User decisions still open / awaiting feedback

1. **Signing (biggest UX pain):** choose free Apple ID in Xcode Accounts vs. agent-created self-signed cert in login keychain (one password prompt). Either → one final re-grant, then permissions survive rebuilds. Asked multiple times; unanswered.
2. **Live checks pending:** real Discord call during dictation (config-change recovery); ⌃⌥Z in a real app; edit-learning loop in TextEdit (same fix twice → auto-learned); continuation casing mid-sentence; Touch Bar tray/idle/recording items incl. Esc while the bar is up; panel drag/hover feel; Fn dictation with the panel visible (stall regression); history→dictionary actions.
3. `LanguageExperimentTests.swift` is diagnostic scaffolding — keep as opt-in or delete before any public push.

## Working conventions

- `main` has reviewed commits (6 so far); the owner commits after reviewing each round — **agents never commit**. Substantive implementation via subagent/sidekick handoffs; owner reviews snapshots + diffs.
- Verify: tests green → `install.sh` → confirm models ready + window/panel on screen → leave app running. Re-render `spike/ui-snapshots/` after visual changes.
- Style: compact idiomatic Swift 6, no gratuitous comments, engines behind protocols, tests with fakes, `.public` privacy on logs, no transcript text in logs.
- Never: commits/pushes without explicit ask; destructive ops without confirmation; network calls beyond model download.
