# Side panel adjustment — 2026-10-02

## Requested behavior

Resting panel shows app status, active/resolved microphone, and a brief summary. It moves around the desktop. Transparent panel area must not block the apps beneath it.

## Implementation

- 148×264 resting summary; 240×424 details on hover.
- Dedicated top grab handle moves the panel in both directions; screen coordinates persist in `sidePanelOrigin`.
- Snaps to either edge within 20pt; becomes a rounded card away from the edge. Clamps to the selected display’s visible frame.
- Nonactivating card-sized window replaces the old full-height 250pt strip.
- Shared outline controls drawing and window-level `ignoresMouseEvents`; mouse monitors handle reentry even when the window is ignoring input. Hide removes monitors and cancels hover work.
- Recording/processing status is distinguished. Stop stays available while recording even if a model or permission later becomes unavailable.

## Evidence

The original window-server regression failed: a mouseDown above the visible tab resolved to Hush’s invisible full-height window. A view returning nil from `hitTest` did not route that event to another app.

`swift test --package-path Packages/HushKit --skip-update` passed. Five model integration/benchmark tests remained skipped without `HUSH_INTEGRATION=1`. No models were downloaded.

Debug and Release builds passed with package-plugin/macro validation skipped. `scripts/install.sh` installed and launched `/Applications/Hush.app`.

The executable’s `--render-snapshots <dir> --verify-side-panel` probe passed these checks:

- invisible former strip routes mouseDown to the app beneath;
- panel stays nonactivating;
- transparent curved corner routes mouseDown beneath;
- visible body receives mouseDown;
- controller drag moves the real window in both directions and changes to floating shape;
- opposite-edge docking remains within the display.

Native UI readback confirmed the resting summary and active microphone. Invoking its Settings button opened Settings. The live app shows both models ready and needs renewed permission grants after ad-hoc reinstall.

Rendered ready, loading, missing-access, recording, processing, long-microphone-name, floating, left-docked, and expanded states were checked. Updated snapshots are under `spike/ui-snapshots/edge-*.png`.

The computer-use service could not target the nonactivating click-through panel for coordinate dragging (`noWindowsAvailable` / `windowNotFoundAtPosition`). The user then tested the installed app and confirmed **both dragging the top handle and clicking outside the panel work**. Controller movement and window-server routing also passed separately. Physical multi-display dragging was not tested on this single-display session.

## Review

Inline review of the task-selected untracked Swift files, DESIGN.md, and HANDOFF.md against the request and AGENTS.md found no remaining code or requirement findings. No commit, push, dictionary/transcription changes, or permission changes were made. Repository files remain uncommitted as before.
