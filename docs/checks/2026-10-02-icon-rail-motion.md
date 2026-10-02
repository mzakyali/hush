# Icon rail and motion verification — 2026-10-02

## Requested behavior

- Resting panel is a compact icon summary, inspired by the supplied curved edge strips.
- Dragging may temporarily move it away from the edge; release always docks to the nearest left/right edge and preserves the vertical position within the display.
- Add motion across the app while respecting Reduce Motion and retaining reliable click-through.

## Implementation

The resting rail is 56×260pt: status ring, active microphone/device menu, activity, record/stop, and Settings. Tooltips and accessibility labels carry the full status/device names. Hover reveals the 240×424pt detail view. The shared outline drives both clipping and window-level mouse routing.

Panel geometry glides for 26 steps (~420ms) and updates mouse routing on every step. Dragging starts from the actual window frame, including during expansion, so grabbing the expanded card does not jump. Release persists the nearest edge immediately. Navigation selection/page transitions, numeric readouts, activity dots, history expansion/copy feedback, and button press/hover states also animate. Reduce Motion removes spatial/symbol movement and snaps immediately; no idle frame timer was added.

## Evidence

- `swift test --package-path Packages/HushKit --skip-update`: exit 0. Swift Testing reported 112 cases across ten targets, including five explicitly skipped model integration/benchmark cases. No model downloads were requested. Log: `/tmp/hush-rail-tests.log`.
- Debug `xcodebuild` with `-skipPackagePluginValidation -skipMacroValidation`: exit 0, `BUILD SUCCEEDED`. Log: `/tmp/hush-rail-build-final.log`.
- `scripts/install.sh`: exit 0, Release `BUILD SUCCEEDED`, installed and launched `/Applications/Hush.app`. Log: `/tmp/hush-rail-install-final.log`.
- Both the final Debug executable and installed Release executable passed `--render-snapshots <dir> --verify-side-panel`. Logs: `/tmp/hush-rail-reviewed.log`, `/tmp/hush-rail-release.log`.
- The native-window probe verifies WindowServer lookup routes the old invisible strip and transparent corner underneath, routes the visible body to Hush, and keeps the panel non-key. It exercises both nearest-edge snaps, hover expansion, continuous expanded-card dragging, and immediate snapping under an injected Reduce Motion preference.
- The nearest-right-edge check failed against the previous free-floating behavior (`/tmp/hush-rail-red.log`), then passed after the docking change. A later synthetic hover check was corrected to continue pointer synchronization through the final snap tick; all final checks pass.
- Visually inspected compact/expanded, left/right, loading, recording, reduced-motion, Home, and expanded History snapshots. Regenerated `spike/ui-snapshots/`. Preview rendering substitutes the native microphone menu with its identical icon label because ImageRenderer cannot render native menus; the installed app retains the real menu.
- Native UI readback confirmed Home → History navigation and history expansion. In the final installed app, closing the main window exposed the compact rail with the correct microphone/activity labels; its microphone menu opened and was cancelled without changing selection. Both models reported Ready. Permissions still require re-approval after ad-hoc signing, so the real rail correctly showed NEEDS ACCESS and disabled Start.

## Scope and remaining checks

Source review covered the selected panel, motion, preview, model-state, and documentation files; no unresolved task-related defect was found. There is no tracked Git baseline (the repository is untracked), so this was a working-source review. No commit or push was made.

The regression probe calls the real controller and checks real native windows; it does not synthesize a physical handle gesture. The user confirmed handle dragging and outside clicks in the previous version. Physical gesture feel on this refinement, cross-app focus with real clicks, and multiple-display dragging remain manual checks. Static snapshots do not establish animation frame rate; no performance benchmark or fresh dictation was run.
