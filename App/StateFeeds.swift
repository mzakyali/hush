import AppKit
import SwiftUI

/// Hot, high-frequency UI state split out of `AppModel`. Before the split,
/// `levelHistory` (~12 Hz while recording) and `edgePanelSize` (every hover
/// animation frame) republished the one AppModel that every view observes, so
/// the whole UI re-evaluated per tick. Views subscribe only to the feed whose
/// state they read; AppModel's own publishes drop to a few per dictation.
@MainActor
final class RecordingFeed: ObservableObject {
    /// Overlay pill states — the bottom panel only exists during dictation.
    enum OverlayState: Equatable {
        case hidden, recording, processing, done, copied, error(String), cancelled
    }
    /// Drives enter/exit transitions (entering/exiting are animation start points).
    enum OverlayPhase { case hidden, entering, visible, exiting, exitingCancel }

    nonisolated init() {}

    @Published var overlayState: OverlayState = .hidden {
        didSet { onOverlayStateChange?() }
    }
    @Published var overlayPhase: OverlayPhase = .hidden
    /// Smoothed, dB-mapped levels, newest first — the wave reads `[0]` for its
    /// amplitude; the rest of the history is retained for future use.
    @Published var levelHistory: [Float] = []
    /// Set when the pill lands on .done — the wave-settle → checkmark timing.
    var doneAt = Date()
    /// Pill bounds in overlay-panel coordinates — the window accepts clicks
    /// only inside it; written by the view via a preference key.
    var pillHitRect = CGRect.zero
    var smoothedLevel: Float = 0
    var overlayGeneration = 0
    /// Wired by AppModel to `OverlayWindowController.syncInteraction()` —
    /// replaces the old `overlayState.didSet` on the model.
    var onOverlayStateChange: (@MainActor () -> Void)?
}

/// Side-panel geometry — `edgePanelSize` moves on every hover-animation frame
/// and `edgeExpanded`/`edgeAttachment` change during drags.
@MainActor
final class SidePanelGeometry: ObservableObject {
    nonisolated init() {}

    @Published var edgeExpanded = false
    /// Which screen edge the panel is docked to (or floating mid-screen).
    @Published var edgeAttachment: SidePanelAttachment = .right
    /// Live frame size while the panel animates between summary and detail.
    @Published var edgePanelSize: CGSize = .zero
}

/// History audio playback — `progress` ticks at 10 Hz while a recording
/// plays, so only the expanded row's player observes it.
@MainActor
final class PlaybackFeed: ObservableObject {
    nonisolated init() {}

    @Published var playingDictationID: String?
    /// 0…1 playback progress of `playingDictationID`.
    @Published var progress: Double = 0
}
