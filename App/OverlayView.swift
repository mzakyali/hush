import HushCore
import SwiftUI

/// Bottom-of-screen overlay (DESIGN.md): a 148 × 32 capsule holding a 25 × 7
/// travelling sine wave of dots — only lit dots render, there is no matrix.
/// The panel exists only during dictation; the idle affordance is the
/// right-edge side panel (`EdgePanelView`).
struct OverlayPillView: View {
    @ObservedObject var model: AppModel

    // Wave grid: 25 columns × 7 rows, 3pt dots on a 5pt horizontal pitch and
    // a 3.5pt vertical pitch → 123 × 24 inside ~12pt padding → 148 × 32 pill.
    static let columns = 25
    static let rows = 7
    static let dot: CGFloat = 3
    static let hPitch: CGFloat = 5
    static let vPitch: CGFloat = 3.5
    static let gridSize = CGSize(
        width: CGFloat(columns) * hPitch - (hPitch - dot),
        height: CGFloat(rows) * vPitch - (vPitch - dot))
    static let pillSize = CGSize(width: 148, height: 32)
    /// Room below the pill inside the 360 × 90 panel for the drop shadow.
    static let bottomInset: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pill bounds in panel coordinates — the window accepts mouse events
    /// only inside it, so transparent margins fall through to apps beneath.
    private struct PillFrameKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    var body: some View {
        Group {
            if needsTimeline {
                TimelineView(.animation) { timeline in
                    pill(now: timeline.date)
                }
            } else {
                pill(now: Date())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Self.bottomInset)
        .coordinateSpace(name: "panel")
    }

    /// Animation states drive a TimelineView; static states render once.
    private var needsTimeline: Bool {
        switch model.overlayState {
        case .recording, .processing, .done: return true
        default: return false
        }
    }

    private var phase: AppModel.OverlayPhase { model.overlayPhase }

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        switch phase {
        case .entering: return 0.92
        case .exitingCancel: return 0.85
        case .exiting: return 0.96
        default: return 1
        }
    }

    private var enterOffset: CGFloat {
        phase == .entering && !reduceMotion ? 10 : 0
    }

    private var opacity: Double {
        switch phase {
        case .entering, .exiting, .exitingCancel: return 0
        default: return 1
        }
    }

    // MARK: - pill shell

    private func pill(now: Date) -> some View {
        content(now: now)
            .padding(.horizontal, 12.5)
            .frame(minWidth: Self.pillSize.width, minHeight: Self.pillSize.height)
            .fixedSize()
            .background(Capsule().fill(Theme.Color.window.opacity(0.94)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .scaleEffect(scale)
            .offset(y: enterOffset)
            .opacity(opacity)
            .contentShape(Capsule())
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PillFrameKey.self,
                        value: proxy.frame(in: .named("panel")))
                }
            )
            .onPreferenceChange(PillFrameKey.self) { rect in
                model.pillHitRect = rect
            }
            .animation(Theme.Motion.spring, value: model.overlayPhase)
    }

    // MARK: - states

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch model.overlayState {
        case .recording:
            wave(now: now,
                 amplitude: max(0.04, Double(model.levelHistory.first ?? 0) * 3),
                 period: 0.9, tint: Theme.Color.textPrimary,
                 hotCenter: Double(model.levelHistory.first ?? 0) > 0.15)
        case .processing:
            wave(now: now, amplitude: 1, period: 0.6,
                 tint: .white.opacity(0.55), hotCenter: false)
        case .done:
            doneContent(now: now)
        case .copied:
            copiedContent
        case .error(let message):
            errorContent(message)
        case .cancelled:
            // A dim flat line while the pill shrink-fades out.
            wave(now: now, amplitude: 0, period: 1,
                 tint: Theme.Color.textPrimary.opacity(0.5), hotCenter: false)
        case .hidden:
            EmptyView()
        }
    }

    /// Recording + processing share this: a travelling sine of lit dots.
    /// Per column, y = A·env(x)·sin(2π·1.6x − 2πt/period) with env = sin(πx)
    /// tapering the ends onto the centre line; the row nearest y is lit.
    /// A second strand runs opposite phase at 0.6× amplitude, 35% opacity.
    private func wave(now: Date, amplitude: Double, period: Double,
                      tint: Color, hotCenter: Bool) -> some View {
        Canvas { ctx, size in
            let t = reduceMotion ? 0 : now.timeIntervalSince1970
            let ox = (size.width - Self.gridSize.width) / 2
            let midY = size.height / 2
            for c in 0..<Self.columns {
                let x = Double(c) / Double(Self.columns - 1)
                let env = sin(.pi * x)
                let phase = 2 * .pi * 1.6 * x - 2 * .pi * t / period
                let row = (amplitude * env * sin(phase)).rounded()
                let hot = hotCenter && abs(c - Self.columns / 2) <= 1
                ctx.fill(Path(ellipseIn: CGRect(
                    x: ox + CGFloat(c) * Self.hPitch,
                    y: midY - row * Self.vPitch - Self.dot / 2,
                    width: Self.dot, height: Self.dot)),
                    with: .color(hot ? Theme.Color.signal : tint))
                // Echo strand: opposite phase at 0.6× amplitude.
                let echoRow = (-0.6 * amplitude * env * sin(phase)).rounded()
                ctx.fill(Path(ellipseIn: CGRect(
                    x: ox + CGFloat(c) * Self.hPitch,
                    y: midY - echoRow * Self.vPitch - Self.dot / 2,
                    width: Self.dot, height: Self.dot)),
                    with: .color(tint.opacity(0.35)))
            }
        }
        .frame(width: Self.gridSize.width, height: Self.gridSize.height)
    }

    // MARK: - done / copied / error

    /// Done: the wave settles to its centre line for 150 ms, then a checkmark
    /// in `signal` for 450 ms before the pill exits.
    private func doneContent(now: Date) -> some View {
        let elapsed = now.timeIntervalSince(model.doneAt)
        return ZStack {
            wave(now: now, amplitude: 0, period: 1,
                 tint: Theme.Color.textPrimary, hotCenter: false)
                .opacity(elapsed < 0.15 ? 1 : 0)
            if elapsed >= 0.15 {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Color.signal)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.gridSize.width, height: Self.gridSize.height)
        .animation(.easeOut(duration: 0.15), value: elapsed < 0.15)
    }

    private var copiedContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("COPIED").tileLabel()
        }
    }

    private func errorContent(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.error)
            Text(message.uppercased()).tileLabel()
                .foregroundStyle(Theme.Color.error)
        }
    }
}
