# Cleanup disfluencies and sentence capitalization — 2026-10-03

## Report and diagnosis

Two recent dictations retained “the... sorry... the...” even though the cleanup model ran and the history did not mark a fallback. The first exact transcript was replayed through `GuardedCleaner` + the cached local Qwen model: it returned the hesitation unchanged. The integration assertions for removing “sorry” and the ellipses failed (`/tmp/hush-cleanup-restart-red.log`, exit 1).

The original prompt emphasized retaining every word and did not explicitly distinguish abandoned starts from intended content. A prompt-only experiment removed the start but dropped the trailing question; coverage correctly rejected it. A shortened illustrative example then caused the second transcript to be summarized. Direct model output and coverage isolated both failures; the final examples preserve complete thoughts and the trailing question. No content-loss threshold was loosened.

A separate public `GuardedCleaner` regression showed that legitimate removal in “the... sorry... the... side panel” was rejected as lost content (`/tmp/hush-cleanup-restart-second.log`, exit 1). Coverage now excludes only the earlier matching 1–4-word start and its correction cue when an explicit ellipsis pause precedes the cue. A repeated pronoun in “I'm sorry I'm late” does not qualify. Coverage remains a multiset for other repetitions, and genuine apologies, trailing instructions, empty output, and timeout fallback retain protection.

The screenshot's “Both” started a separate recording. Cleanup receives that recording's transcript, not the preceding field text, so capitalizing its first word is expected. No insertion-context or blanket lowercasing change was made.

## Changes

- CleanupPrompt: explicitly remove stutters and abandoned starts; preserve genuine apologies, all completed sentences, redundant questions, language mix, names and identifiers; use sentence case.
- CleanupGuard: narrowly exempt explicitly paused repeated starts from content coverage.
- CleanupTests: accept legitimate restart removal; reject lost apologies and trailing instructions, including the repeated-pronoun apology control.
- Local integration replay: both exact reported transcripts, genuine apology, ordinary lowercase words, names/identifiers, and original Indonesian/mixed input. Local weights are required for the new replay; it cannot download a missing model.
- GPU integration tests run serially. Running both model tests concurrently triggered their eight-second production timeout; serial execution reflects the app's single cleanup request and passed without increasing the timeout.

## Verification

- `HUSH_INTEGRATION=1 swift test --package-path Packages/HushKit --skip-update --filter CleanupTests`: exit 0, 31 tests reported, benchmark opt-in skipped. Both local-model integration tests passed (`/tmp/hush-cleanup-serialized-integration.log`).
- First replay: “Can you find out why sometimes the clean up version has capitalized words that don't have to be capitalized? Do you know why?”
- Second replay: “Also yeah, like this, it doesn't have to be like that, I think; it should be cleaned up.”
- Debug app build: exit 0 (`/tmp/hush-cleanup-build.log`).
- Full logic suite: `swift test --package-path Packages/HushKit --skip-update`, exit 0; model/benchmark experiments remain opt-in (`/tmp/hush-cleanup-final-tests.log`).
- Release installation: `scripts/install.sh`, exit 0; Release build succeeded and `/Applications/Hush.app` was replaced and launched (`/tmp/hush-cleanup-install.log`). Ad-hoc signing may require permission grants to be renewed.

This verifies the text cleanup seam with the actual cached model. New live microphone recordings have not been replayed by the user on the installed update. Generative cleanup remains guarded; other phrasing may still fall back when a model loses intended content.
