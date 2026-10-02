# Hush v1 — local voice dictation for macOS

Status: draft, decisions settled except where marked **OPEN**.
Owner/user: single user (Zaky), personal use, one Mac.

## 1. Problem and outcome

Typing is slower than speaking. Hush lets the user dictate into any macOS app with a hotkey, in English, Indonesian, or a mix of both in one sentence, and get cleaned-up text inserted where they are working. Everything runs on-device; no audio or text leaves the Mac.

Success: dictating a typical 1–3 sentence message is faster than typing it, needs few manual fixes, and the fixes the user does make teach Hush over time.

## 2. Environment (verified 2026-10-01)

- Apple M1, 16 GB RAM, macOS 26.6, Xcode 27, Swift 6.4.
- Apple built-ins rejected (probe run on this Mac):
  - `SpeechTranscriber`: no `id-ID`.
  - `DictationTranscriber`: has `id-ID` but one locale per session — cannot handle EN/ID code-switching.
  - `SFSpeechRecognizer` `id-ID`: not on-device.
  - Foundation Models: Apple Intelligence disabled; Indonesian not in supported languages.

## 3. Scope

### v1
1. Menu-bar app plus a main window (history, dictionary, stats, settings). Dock icon shown by default with a **Show in Dock** setting to switch to menu-bar-only (matches Wispr Flow). Launch at login.
2. Two global hotkeys: **hold-to-talk** and **toggle** (press to start, press to stop). Both configurable.
3. Recording overlay: small non-activating floating panel; never steals focus or blocks clicks. Shows recording state, level meter, and live partial transcript.
4. **Esc** while recording cancels: nothing is inserted, nothing is saved.
5. Transcription: local multilingual ASR, EN + ID with code-switching.
6. Cleanup: local LLM removes fillers ("um", "eh", "anu", "gitu"…), fixes punctuation/capitalization, formats lists, preserves the spoken language mix (never translates).
7. Per-app style: profile chosen by frontmost app bundle ID at insertion time.
   - Defaults: `casual` (Slack, WhatsApp, Discord, Messages, Telegram), `formal` (Mail, Outlook), `minimal` (Xcode, VS Code, Windsurf, Cursor, Terminal, iTerm, Ghostty — punctuation only, never rewrite identifiers), `default` for everything else. User can add/edit mappings.
8. Insertion target: the app focused **when recording stops**. If no text input is focused, copy to clipboard and show a notification "Copied to clipboard".
9. Paste-raw undo: hotkey that replaces the last insertion with the raw (uncleaned) transcript. Only valid while the target field still contains the inserted text.
10. Dictionary (see §5) with three uses: ASR prompt biasing, deterministic replacement rules, LLM vocabulary.
11. Self-improving dictionary from manual edits (see §6).
12. History: searchable list of past dictations with raw text, cleaned text, app, timestamp, duration, and audio playback; re-transcribe and "add to dictionary" from a selected word.
13. Retention: transcripts **and** audio auto-deleted after **30 days** (configurable). Dictionary, suggestions, settings, stats aggregates are never auto-deleted.
14. Media and mic: auto-pause playing media during recording and resume after (toggleable). Input device selection per §4a.
15. Stats: words dictated, sessions, average WPM spoken, estimated time saved vs. typing (typing WPM configurable, default 40) — per day/week, kept as aggregates so they survive retention.

### v2 (non-goals for v1)
- Command mode (voice-edit selected text).
- Snippets / voice shortcuts.
- Translation output, other languages, sync, iOS, App Store distribution.

## 4. Pipeline

```
hotkey down/toggle → AudioCapture (16 kHz mono) ─┬→ streaming ASR partials → overlay
                                                 └→ on stop: final ASR (with dictionary prompt)
→ ReplacementRules → Cleanup LLM (style profile + dictionary terms) → ReplacementRules (again, guarantees)
→ Inserter (target = frontmost app at stop) → History + Stats → EditWatcher
```

Invariants
- No network access after model download. Model download is the only network call and is explicit/user-initiated.
- Inserter restores the user's previous clipboard contents after paste.
- Never read or watch secure text fields (`AXSecureTextField`) or when Secure Event Input is on.
- Cleanup must never drop content: if the LLM output length deviates beyond a threshold from the raw text, or the LLM fails/times out, insert the rule-processed raw text instead and mark the history entry `cleanupFallback`.
- Models are loaded lazily, kept warm while in use, unloaded after an idle period (default 10 min).

Latency target: ≤ 1.5 s from stop to inserted text for a ≤ 15 s utterance on this M1. To be confirmed by the spike (§9).

## 4a. Microphone priority

- Settings shows every input device Hush has ever seen as a drag-to-reorder priority list (top = highest). Devices are identified by CoreAudio device UID so the order survives reconnects and reboots. Disconnected devices stay in the list, greyed out.
- A newly seen device is added at the **bottom**; the user drags it up if wanted.
- **Auto mode** (default): Hush uses the highest-priority connected device. It listens for device connect/disconnect (`kAudioHardwarePropertyDevices`) and re-selects immediately; a switch never happens mid-recording — it applies to the next recording.
- **Manual pick** (menu bar → Microphone → device): pins that device and overrides priority. The pin is released, and auto mode resumes, when the pinned device disconnects or the user picks "Automatic".
- Hush selects its own input device; it does not change the macOS system default input.
- If the chosen device fails to start, fall back to the next connected device in priority order and show a notification.
- Overlay shows the active mic name when recording starts.
- Note for users: using AirPods as the mic switches them to the Bluetooth call profile, which lowers playback quality — a reason to keep them low priority.

## 5. Dictionary

Entry kinds
- **Term**: a word/phrase the ASR should recognize (e.g. "Supabase", "Hush", a person's name). Fed to ASR as prompt tokens and to the LLM as "spell these exactly".
- **Replacement**: `from → to`, whole-word, case-insensitive match (e.g. "super base" → "Supabase", "gw" → "gue"). Applied deterministically before and after cleanup.

Each entry records `source` (`manual` | `learned` | `history`), `createdAt`, `hitCount`.

## 6. Self-improving dictionary

1. After insertion, `EditWatcher` records the inserted text and the target AX element.
2. It observes that element (AX value-changed notifications, or polling as fallback) until focus leaves the element or 60 s pass.
3. At end of watch, diff inserted vs. current text at word level; keep only small substitutions (1–3 tokens replaced by 1–3 tokens). Ignore insertions/deletions of whole sentences and anything beyond a total edit-ratio threshold.
4. Each candidate `from → to` becomes a **suggestion**. Seen once → shown in the menu for one-click approve/reject. Seen twice (same pair) → auto-added as a `learned` replacement (and `to` added as a Term). Rejected pairs are never suggested again.
5. If the app does not expose AX text (terminals, some Electron/web editors), the watch silently does nothing.

## 7. Data and storage

Location: `~/Library/Application Support/Hush/`
- `hush.sqlite` — tables: `dictations`, `dictionary_entries`, `suggestions`, `app_styles`, `stats_daily`.
- `audio/<dictation-id>.m4a` — AAC, 16 kHz mono, ~32 kbps (~0.24 MB/min).
- `models/` — downloaded ASR and LLM weights.

Retention job runs at launch and daily: delete `dictations` rows and their audio older than the retention window.

## 8. Architecture

Native Swift (SwiftUI + AppKit), Swift Package Manager modules behind protocols so engines are swappable and testable:

| Module | Responsibility |
|---|---|
| `HotkeyService` | Global hold/toggle/Esc/undo hotkeys (CGEventTap) |
| `AudioCapture` | AVAudioEngine, device selection, level meter, m4a writing |
| `Transcriber` (protocol) | `transcribe(audio, prompt:) async -> Transcript`, streaming partials |
| `Cleaner` (protocol) | `clean(raw, style, terms) async -> String` |
| `Dictionary` | Terms, replacements, suggestions |
| `Inserter` | Focus/target detection, pasteboard + ⌘V, clipboard restore, raw-undo |
| `EditWatcher` | AX observation and diff → suggestions |
| `MediaController` | Pause/resume now-playing media |
| `Store` | SQLite persistence, retention, stats |
| `App` | Menu bar, overlay, settings, history, onboarding (mic + Accessibility permissions) |

Distribution: local build, not sandboxed (Accessibility + CGEventTap), Developer ID or ad-hoc signed.

## 9. Models and validation

Settled defaults (user chose the mainstream choice for local dictation apps):
- ASR: Whisper **large-v3-turbo** via WhisperKit (Core ML). Also used by VoiceInk, MacWhisper and superwhisper's local mode.
- Cleanup: **Gemma 3 4B instruct, 4-bit, via MLX Swift** — chosen for its broad multilingual training, which includes Indonesian. Fallback if validation fails: Qwen3 4B instruct, 4-bit.

Validation (optional, does not block implementation; swap via the `Transcriber`/`Cleaner` protocols if results are poor):
- Inputs: 8–10 real recordings by the user: English, Indonesian, and code-switched; short (≤5 s) and medium (10–20 s); include dictionary-type words.
- Measure: word error rate vs. hand-written reference, stop→text latency, peak RAM, and cleanup quality (language preserved, no content dropped, fillers removed).

## 10. Acceptance examples

- Hold hotkey in Slack, say "eh nanti kita deploy ke production ya, um, after lunch" → Slack receives `Nanti kita deploy ke production ya, after lunch.`
- Toggle, switch from Notes to Mail mid-recording, stop → text lands in Mail with formal style.
- Stop with Finder desktop focused → text on clipboard, notification shown.
- Esc during recording → nothing inserted, no history row.
- Paste "super base", user edits to "Supabase" twice across sessions → `super base → Supabase` replacement exists with `source = learned`.
- History entry older than 30 days → row and m4a gone after retention job.
- Wi-Fi off after model download → all features work.

## 11. Open questions

- Default hotkeys settled: hold = **Fn**, toggle = **⌥⌥ double-tap**, paste-raw = **⌃⌥Z**. Implementation must verify Fn capture via CGEventTap on this keyboard, and stop macOS's own Fn action (emoji picker or Apple dictation) from also firing; if Fn can't be captured reliably, fall back to holding Right-⌥.
- Typing WPM default 40, user-adjustable.

No open product questions. Ready for `writing-plans`.
