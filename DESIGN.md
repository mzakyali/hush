# Hush — design system

World: **"Instrument panel."** Hush is a quiet piece of hardware on your desk: dark charcoal tiles, a single hot signal colour, numbers set like readouts, voice drawn as a dot-matrix display. References chosen by the user: DeerFlow dot-matrix tiles (dot waveform, dot charts), Metric Flow / Sapphire bento dashboards (charcoal tiles, hatched heatmaps), RON fleet dashboard (light large numerals with dimmed decimals), Knob by Work Louder (black pill device, orange signal).

Mode: **Operate.** Dark only (for now). Native macOS behaviours (sidebar, forms, keyboard focus, VoiceOver labels) are never sacrificed for looks.

## Tokens

### Colour
| Token | Value | Use |
|---|---|---|
| `bg.window` | `#0B0B0C` | Window and content background |
| `surface.tile` | `#161618` | Tiles (the only container) |
| `surface.raised` | `#1F1F22` | Hover, selected nav item, keycaps, inputs |
| `stroke.hairline` | white 7% | 1px separators, pill outline. Never combined with a shadow on tiles |
| `text.primary` | `#F2F0EC` | Primary text, lit dots |
| `text.secondary` | white 62% | Secondary text, labels |
| `text.tertiary` | white 40% | Timestamps, dimmed decimals, units |
| `dot.off` | white 9% | Unlit matrix dots, empty heatmap cells |
| `signal` | `#FF5B2E` | The voice, the active thing, today. Max one signal element per tile |
| `signal.soft` | signal 22% | Selected-state washes, low heat |
| `ok` | `#3DDC84` | Status dot "ready / granted" only |
| `warn` | `#FFB020` | Status dot "needs action" only |
| `error` | `#FF6B6B` | Error text/dot only |

All text ≥ 4.5:1 on its surface (text.tertiary is only used ≥ 11pt for non-essential metadata).

### Type
| Role | Face | Size / line | Weight | Tracking | Notes |
|---|---|---|---|---|---|
| `display` | Instrument Serif | 56 / 60 | Regular | −0.02em | Home hero number only. Decimals/units in text.tertiary |
| `title` | SF Pro Display | 22 / 28 | Semibold | −0.01em | Page title |
| `heading` | SF Pro Text | 15 / 20 | Semibold | 0 | Tile heading, day header |
| `body` | SF Pro Text | 13 / 18 | Regular | 0 | Everything else |
| `caption` | SF Pro Text | 12 / 16 | Regular | 0 | Secondary lines |
| `label` | Geist Mono | 11 / 14 | Medium | +0.06em | UPPERCASE tile labels |
| `data` | Geist Mono | 13 / 18 | Regular | 0 | Numbers, times, counts, shortcuts; tabular figures |
| `data.lg` | Geist Mono | 20 / 24 | Regular | −0.01em | Secondary readouts in tiles |

Fonts are bundled (OFL): Geist Mono (vercel/geist-font), Instrument Serif (google/fonts `ofl/instrumentserif`). Licences ship in `App/Fonts/`.

### Space, shape, depth, icons
- Spacing scale: 4, 8, 12, 16, 24, 32, 48. Tile padding 20. Grid gap 12. Content padding 32.
- Radii: tile 16, control 8, keycap 6, heat cell 3, pill = capsule.
- Depth: tiles are flat (no shadow, no border) on `bg.window`. Only floating things (overlay pill, popovers) get a shadow: `0 10 30` black 50%.
- Icons: SF Symbols only, `.regular` weight, 14pt in nav/rows, 13pt in buttons. No emoji, no unicode glyphs as icons.

### Motion
Motion thesis: Hush behaves like a responsive instrument. The focal interaction is the rail gliding home to its nearest edge and opening into its details. Supporting motion explains navigation, updated measurements, and actions.
- **Continuity:** selected sidebar background travels between destinations; pages slide/crossfade over ~380ms. History expansions use a short spring.
- **Readouts:** numbers roll when their values change; activity dots interpolate occupancy rather than jump. No endless dashboard loops.
- **Feedback:** controls compress on press, brighten or grow slightly on hover; copy changes briefly to a checkmark. Rail status uses a short opacity transition and a steady status ring; avoid SF Symbol pulse/replacement effects in this transparent panel (they stalled live dictation's UI rendering on this machine).
- **Budget:** geometry animation runs for 26 frames only, with no idle render timer. The status rail has no repeating symbol animation. Repeated navigation/dragging interrupts the previous animation.
- **Reduce Motion:** disable panel geometry motion, page offsets, sidebar travel, bouncing/pulsing symbols, and control scaling. Keep short fades, color feedback, and immediate edge snapping. The approved recording waveform/pill remains as specified below.

## Components

### Dot matrix
The signature primitive. A grid of round dots (diameter `d`, gap `g`), each dot either `dot.off`, `text.primary` (lit) or `signal` (hot). Used by: overlay waveform, weekly bars, model/loading indicators.

### Overlay pill
- Size 148 × 32 capsule (text states may widen to fit; min 148). Fill `#0B0B0C` at 94%, inner 1px `stroke.hairline` at white 10%, shadow `0 10 30` black 50%. Lives in a fixed 360 × 90 transparent non-activating panel with the pill centred at the bottom so width changes and the shadow are never clipped. Clicks land only inside the capsule — transparent margins click through — and only while recording (click to stop).
- Position: pill bottom 20pt above `visibleFrame.minY` (clears the Dock), on the screen containing the mouse when recording starts. The panel exists only during dictation — the idle affordance is the side panel below. Repositions on screen-parameter changes.
- **Wave:** 25 columns × 7 rows, dot 3pt, horizontal pitch 5 (gap 2), vertical pitch 3.5, ~12pt side padding. Only lit dots render — there is no off-dot grid, so the capsule shows just the wave. Per column x = c/24: `y = A · sin(πx) · sin(2π·1.6x − 2πt/period)` — the sin(πx) envelope tapers the ends onto the centre line. The row nearest y is lit; an echo strand runs opposite phase at 0.6× amplitude, 35% opacity.
- **Recording:** period 0.9 s. Amplitude A = smoothed level (newest `levelHistory`) × 3 rows, 0.04 floor → silence is a flat centre line. Lit dots `text.primary`; the 3 centre columns of the main strand use `signal` when level > 0.15.
- **Processing:** same wave, constant 1-row amplitude, white 55%, period 0.6 s. No level input.
- **Done (pasted):** wave settles to the flat centre line for 150 ms, then a `checkmark` SF Symbol 13pt in `signal` appears for 450 ms, then the pill exits.
- **Copied to clipboard:** `doc.on.clipboard` 13pt + `COPIED` in `label`, 1.2 s, exit.
- **Error:** `exclamationmark.triangle` in `error` + short `label` text (e.g. `NO SPEECH`), 1.5 s, exit.
- **Enter:** from y+10, scale 0.92, opacity 0 → 1 with default spring. **Exit:** scale 0.96 + fade, 160 ms. **Cancel (Esc):** dim flat line, scale 0.85 + fade, 160 ms.
- **Reduce Motion:** no travelling — a static wave still scaled by level.

### Side panel
Hush's idle affordance is a slim, icon-only rail, always docked to the left or right screen edge when at rest.
- **Resting rail:** 56 × 260pt. Top grab handle, status ring/symbol, microphone-device icon, activity icon, record/stop, and Settings. Tooltips/accessibility labels carry status, exact microphone name, and today's words; mic icon opens the input menu. Ready = green check; permissions/model failure = red exclamation; loading = amber download; dictation = orange waveform/processing dots.
- **Shape:** black with concave inverted corners when docked; mirrored on the left. A rounded card is used only transiently while dragging away from an edge. Rendering and mouse routing share `SidePanelShape`.
- **Hover:** begins expanding after 350ms to 240 × 424pt with status text, microphone name, today's words, 7-day dots, WPM, time saved, streak, and dictations. Exit begins collapse after 400ms. Window geometry glides over approximately 420ms with quartic deceleration, and content crossfades inside its clipped outline.
- **Drag:** the top handle moves vertically and between edges/displays. On release, the rail always glides to the nearest left/right edge of its display; it never rests in the middle. Its edge and vertical position persist in `sidePanelOrigin`. Existing floating positions are migrated to their nearest edge on launch. Clamp inside the display's visible frame; legacy `edgeTabFraction` supplies the initial vertical position.
- **Mouse routing:** the window stays the size of the visible outline on every animation frame. Local/global pointer monitors set `NSWindow.ignoresMouseEvents` outside that outline, including transparent corners. Dragging keeps input enabled until release. Hiding cancels hover/frame tasks and removes monitors. Never reintroduce a full-height invisible strip.
- **Right-click menu:** Start/Stop dictation, Microphone, Open Hush, Settings, Hide, Restart, Quit.
- "Show side panel" (default on) remains one of the three access surfaces; hiding it never suppresses the dictation pill.

### Microphone (spec §4a)
- Every input device Hush has seen lives in a drag-to-reorder priority list, persisted by CoreAudio UID (`micPriority` + `micPinnedUID` in UserDefaults). New devices append at the bottom; disconnected ones keep their place, greyed out with a `DISCONNECTED` label. The Settings → Microphone section shows an Input picker (`Automatic (<resolved name>)` + connected devices) above that list; the active device is marked `IN USE`.
- Auto mode resolves the highest-priority connected device at each recording start (`MicSelector.resolve`); a manual pick pins a device until it disconnects or Automatic is re-selected. A CoreAudio `kAudioHardwarePropertyDevices` listener keeps the list live — switches apply to the next recording, never mid-recording.
- If the resolved device fails to start, the next connected candidate in priority order is tried, then the system default; a notification names the failed device and the fallback.
- The same "Microphone" submenu (Automatic + connected, checkmarks) lives in the side panel's right-click menu and the menu-bar extra.

### Window shell
- Default 1000 × 680, min 860 × 580. Full-size content view, transparent title bar, traffic lights over the sidebar. Forced dark appearance.
- Sidebar 216pt on `bg.window` with a 1px hairline on its trailing edge. Top: menu-bar bars mark (16pt) + "Hush" `heading`. Nav: Home, History, Dictionary, Styles; Settings pinned at the bottom. Item 32pt, radius 8, icon 14 + `body`. Selected: `surface.raised` fill, icon tinted `signal`, text primary. Hover: white 4%.
- Content: page `title` at top-left, 32 padding, tiles below on a 12-gap grid.

### Tile
`surface.tile`, radius 16, padding 20. Header row: `label` (uppercase) left, optional `data` or a small button right. Never nest tiles.

### Keycap
`surface.raised`, radius 6, height 22, horizontal padding 7, `data` text 12, 1px bottom inner shade black 40%. Used wherever a shortcut is shown.

### Status dot
6pt circle + `caption` text. `ok` / `warn` / `error` / `text.tertiary` (idle).

### Heatmap
Cells 12 × 12, radius 3, gap 3. Levels: 0 `dot.off`; 1 `signal` at 22% with 45° hatch lines (1pt, signal 50%); 2 signal 45%; 3 signal 70%; 4 signal 100%. Today's cell has a 1px `text.primary` ring.

### List row (history)
Height ≥ 44. Leading: time in `data` 12 `text.tertiary` (fixed 44pt column), app icon 16pt, text `body` single line truncated. Trailing on hover/focus: icon buttons Copy, Play (13pt, 28pt hit area, `surface.raised` on hover). Selected/expanded row: `surface.raised` background radius 8.

### Buttons
- Primary: `signal` fill, text `#0B0B0C` `body` semibold, height 28, radius 8.
- Secondary: `surface.raised` fill, text primary.
- Ghost/icon: transparent, white 6% on hover.
- Focus ring: 2pt `signal` at 60%, offset 2.

## Screens

### Home
Grid of tiles, 3 columns.
1. **Words** (spans 2 columns): label `WORDS DICTATED`, right `data` `ALL TIME`; `display` total words; below it a row of three `data.lg` readouts with `label`s: `TODAY`, `AVG WPM`, `TIME SAVED` (e.g. `1h 12m`). Empty (0 words): display `0` and a caption "Hold fn and start talking." with the fn keycap.
2. **Activity** (1 column): label `ACTIVITY`, right `data` `12 WEEKS`; heatmap 12 columns × 7 rows from daily word counts (quantile levels 1–4 over non-zero days).
3. **System** (1 column): label `SYSTEM`; rows with status dots: Speech model (Whisper large-v3 turbo), Cleanup model (Qwen3 4B), Microphone, Accessibility, Input Monitoring. Model rows show their load state (`Optimizing… 2:14` with timer, `Downloading 42%`, `Ready`, `Failed` + Retry). Permission rows that aren't granted show an "Open Settings" secondary button.
4. **Shortcuts** (1 column): label `SHORTCUTS`; rows: keycap `fn` "Hold to talk", keycaps `⌥` `⌥` "Toggle", `esc` "Cancel", `⌃` `⌥` `Z` "Paste raw". (Keycap glyphs are key legends, not icons.)
5. **Recent** (1 column): label `RECENT`, right ghost button "View all" → History; the last 5 list rows.

### History
Title "History", search field (`surface.raised`, radius 8, 32 tall, magnifier symbol) top-right. Sections grouped by day: header `heading` ("Today", "Yesterday", "Mon 28 Sep") + `data` count right. Rows per List row. Click a row → inline expansion: cleaned text (`body`, selectable), an audio player (play/pause button + dot-matrix scrubber 1 row of dots where played dots are `text.primary`, unplayed `dot.off`) and actions Copy, Delete. When `cleanedText == rawText` the RAW block is hidden in favour of a tileLabel chip — `NO CLEANUP NEEDED`, or `CLEANUP FELL BACK` when the LLM errored — and Copy raw is hidden. When they differ, a `CHANGES` block shows a word-level diff (LCS over whitespace tokens, `WordDiff.compute`): removed words `text.tertiary` struck through, added words `signal`; a removed token whose following added token matches modulo case/edge-punctuation (`ship`→`Ship`, `off`→`off.`) coalesces to a `.changed` op rendered as the new word alone in `signal`. Copy raw stays. Empty state: centred dot-matrix flat line + "Your dictations will show up here." + fn keycap hint.

### Dictionary, Styles
Built in the next milestone. Until then: page title + a single tile with a one-line explanation of what the page will do, and no fake controls.

### Settings
Native grouped `Form` in the dark appearance (macOS settings idiom), sections:
- General: Show in Dock (toggle), Launch at login (toggle).
- Shortcuts: read-only keycap rows (editing comes later).
- Models: per-model status row + Retry; storage used (`data`).
- Privacy: "Keep history for" stepper (days, default 30); "Delete all history…" (destructive, confirm alert).
- Permissions: the three permission rows with status + Open Settings.
