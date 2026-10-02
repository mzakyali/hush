# Fn-release regression investigation — 2026-10-02

## Live reproduction

The user confirmed recording continues after releasing Fn. Two live trials reproduced the symptom with the icon rail enabled, leaving the app running. A read-only Fn-state sampler observed HID key/flag transitions:

- First trial: down at 05:33:11 UTC, up at 05:33:13 UTC. The recording pill was still visible with its recording waveform after release. Pipeline completion logged at 05:33:27 UTC for 12.29 seconds of audio; the UI's `recording stopped` log arrived at 05:34:19 UTC.
- Second trial: down at 05:35:22 UTC, up at 05:35:26 UTC. User left the stuck state untouched. Pipeline completion logged at 05:35:35 UTC for 9.38 seconds of audio; UI `recording stopped` logged at 05:37:04 UTC.
- Control: temporarily hid the side panel using its existing Settings switch. User reported prompt stop. HID down/up at 05:39:55/05:39:56 UTC; UI `recording stopped` logged at 05:39:56.716 UTC for 1.19 seconds of audio. Pipeline completed at 05:39:59.147 UTC.

This isolates the visible panel interaction as a factor. It does not yet establish whether the original Fn release is lost/delayed at the event tap, delayed at its MainActor consumer, or delayed while applying pipeline updates. A sample of Hush showed its main thread actively rendering SwiftUI while its dedicated hotkey thread waited in its run loop; this is supporting evidence, not a causal proof of a particular animation modifier.

## Controls and diagnostic limits

- Existing Fn hold/end, pipeline hold/end, toggle, and cancel tests pass. These are controls; they do not reproduce the live native interaction.
- A temporary native scheduling probe used synthetic meter values with the real native panel controls, pill, and recording/processing/done transitions. Cases passed with delays below 10ms, but the process regained activation; this did not reproduce the real background-app symptom. The insensitive probe and its command were removed rather than presented as a passing physical-Fn regression. Logs remain under `/tmp/hush-fn-*-red.log`.
- An external read-only session event tap was created, but received no Fn events while Hush consumed them. Its lack of events does not prove that Hush missed a release.
- Read-only Fn monitoring was limited to key 63 and its modifier flags. No typed text was collected. Temporary sampler/event-trace/sample files and logs are under `/tmp/hush-fn-*` and `/tmp/hush-stuck-*`; probes end automatically.

## In-process trace and candidate fix

Added in-process logs for Fn events, emitted hotkey actions, disabled/re-enabled taps, AppModel receipt of hotkey actions, and applied UI states. All logs exclude transcript/typed-text contents. The diagnostic Release installation and four existing controls passed (`/tmp/hush-fn-diagnostic-install-final.log`, `/tmp/hush-fn-diagnostic-tests.log`).

The diagnostic live trace established that key normalization and emission work: at 05:57:44.968 UTC, Fn flags were false, HIDFn was false, and `holdEnd` was emitted immediately. AppModel received it at 05:57:45.943 and applied processing at 05:57:46.341. Subsequent emitted holds queued behind the UI/processing work. The user reported a delayed stop, a stuck completion checkmark that cleared after clicking the panel, and another run where Stop could not respond.

Sampling the stalled diagnostic process found most main-thread samples inside `RenderBox` shared-surface allocation / Core Animation commit synchronization. Its stack also contained `RBSymbolAnimator` and `pulse_keyframes`. Hiding the panel cleared the UI backlog; CPU returned to idle. Logs and sample: `/tmp/hush-fn-diagnostic-live.log`, `/tmp/hush-fn-before-hide.log`, `/tmp/hush-fn-after-hide.log`, `/tmp/hush-fn-diagnostic-stall-sample.txt`.

The fix removes only the side-panel status icon's repeating pulse and SF Symbol replacement effects, replacing them with a short opacity transition. Other motion and the recording pill design remain. No hotkey or pipeline behavior was changed. Debug build and the full logic suite passed (`/tmp/hush-fn-fix-build.log`, `/tmp/hush-fn-fix-tests.log`; five opt-in cases skipped). The existing native panel probe passed all eight checks (`/tmp/hush-fn-fixed-panel.log`). These checks cover build/logic/window routing; the physical scenario below verifies the original graphics stall.

The side panel was temporarily disabled for live isolation, then restored to on after installation. The user restored permissions and restarted Hush.

The fixed Release build installed and launched successfully (`/tmp/hush-fn-fix-install.log`). Native UI readback confirmed both models Ready, the permission controls visible, and Show side panel restored to on. Recording/processing snapshots were inspected and refreshed.

## Original scenario — green

The user tested two consecutive Fn recordings from another focused app with the panel enabled and confirmed: "Both work; stops promptly and pill clears." The prompt explicitly included prompt release, automatic completion dismissal, and a working second recording.

The installed-build trace (`/tmp/hush-fn-fix-live.log`, process 11128) confirms:

- Release at 06:19:38.361 UTC → emitted holdEnd immediately → AppModel receipt and UI processing at 06:19:38.362 UTC. Recording stopped, then UI returned to idle at 06:19:38.569 UTC.
- Release at 06:19:43.277 UTC → emitted holdEnd immediately → AppModel receipt and UI processing at 06:19:43.278 UTC. Recording stopped at 06:19:43.303 UTC, pipeline completed at 06:19:46.041 UTC, and UI returned to idle at 06:19:46.122 UTC.

This controlled change and successful original scenario establish the side-panel symbol effects as the regression's cause on this machine. The core hotkey/pipeline logic was unchanged. The insensitive synthetic probe was removed; the retained live trace and human-operated reproduction provide the relevant regression evidence. Cross-machine graphics behavior and physical multi-display dragging are outside this check's coverage.
