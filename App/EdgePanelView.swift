import AppKit
import HushCore
import Store
import SwiftUI

enum SidePanelAttachment: String {
    case left, right, floating
}

struct EdgeTabShape: Shape {
    /// Body width — how far the shape reaches from the edge.
    var w: CGFloat
    /// Height of the straight left-side section.
    var h: CGFloat
    /// Concave fillet radii at top/bottom where the shape meets the edge.
    var cx: CGFloat
    var cy: CGFloat
    /// Convex corner radii on the body's left side.
    var rx: CGFloat
    var ry: CGFloat

    /// Cubic quarter-ellipse constant.
    private static let k: CGFloat = 0.5523

    var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>,
        AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(.init(w, h), .init(cx, cy)), .init(rx, ry)) }
        set {
            w = newValue.first.first.first
            h = newValue.first.first.second
            cx = newValue.first.second.first
            cy = newValue.first.second.second
            rx = newValue.second.first
            ry = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let W = rect.maxX, top = rect.minY, left = W - w, k = Self.k
        var p = Path()
        // Top: concave fillet out of the edge, top edge, convex corner.
        p.move(to: CGPoint(x: W, y: top))
        p.addCurve(to: CGPoint(x: W - cx, y: top + cy),
                   control1: CGPoint(x: W, y: top + k * cy),
                   control2: CGPoint(x: W - cx + k * cx, y: top + cy))
        p.addLine(to: CGPoint(x: left + rx, y: top + cy))
        p.addCurve(to: CGPoint(x: left, y: top + cy + ry),
                   control1: CGPoint(x: left + rx - k * rx, y: top + cy),
                   control2: CGPoint(x: left, y: top + cy + ry - k * ry))
        // Body's left side.
        p.addLine(to: CGPoint(x: left, y: top + cy + ry + h))
        // Bottom, mirrored: convex corner, bottom edge, concave fillet.
        p.addCurve(to: CGPoint(x: left + rx, y: top + cy + 2 * ry + h),
                   control1: CGPoint(x: left, y: top + cy + ry + h + k * ry),
                   control2: CGPoint(x: left + rx - k * rx,
                                     y: top + cy + 2 * ry + h))
        p.addLine(to: CGPoint(x: W - cx, y: top + cy + 2 * ry + h))
        p.addCurve(to: CGPoint(x: W, y: top + 2 * cy + 2 * ry + h),
                   control1: CGPoint(x: W - cx + k * cx,
                                     y: top + cy + 2 * ry + h),
                   control2: CGPoint(x: W,
                                     y: top + 2 * cy + 2 * ry + h - k * cy))
        p.closeSubpath()   // flush edge segment
        return p
    }
}

/// One outline shared by the rendering and window-level pointer routing.
struct SidePanelShape: Shape {
    var attachment: SidePanelAttachment

    func path(in rect: CGRect) -> Path {
        if attachment == .floating {
            return RoundedRectangle(cornerRadius: 24).path(in: rect)
        }
        let shape = EdgeTabShape(w: rect.width, h: rect.height - 80,
                                 cx: 18, cy: 18, rx: 22, ry: 22)
        let path = shape.path(in: rect)
        if attachment == .left {
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                  tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}

struct EdgePanelView: View {
    @ObservedObject var model: AppModel
    /// Geometry publishes on every hover-animation frame — a focused feed so
    /// those frames re-render only this view.
    @ObservedObject var geometry: SidePanelGeometry
    var forceExpanded = false
    var forceAttachment: SidePanelAttachment?

    static func size(expanded: Bool) -> CGSize {
        expanded ? CGSize(width: 240, height: 424) : CGSize(width: 56, height: 260)
    }

    private var isExpanded: Bool { geometry.edgeExpanded || forceExpanded }
    private var attachment: SidePanelAttachment { forceAttachment ?? geometry.edgeAttachment }
    @HushReducedMotion private var reduceMotion

    var body: some View {
        let size = forceAttachment != nil || geometry.edgePanelSize == .zero
            ? Self.size(expanded: isExpanded) : geometry.edgePanelSize
        let shape = SidePanelShape(attachment: attachment)
        VStack(spacing: isExpanded ? 12 : 8) {
            dragHandle
            ZStack {
                if isExpanded {
                    expandedContent.transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                } else {
                    summaryContent.transition(.opacity)
                }
            }
            .animation(Theme.Motion.response(reduceMotion), value: isExpanded)
        }
        .padding(.horizontal, isExpanded ? 16 : 8)
        .padding(.vertical, 30)
        .frame(width: size.width, height: size.height)
        .background { shape.fill(Color.black) }
        .clipShape(shape)
        .contentShape(shape)
        .preferredColorScheme(.dark)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: isExpanded ? 16 : 12)
            .overlay {
                if !SnapshotRunner.requested {
                    SidePanelDragHandle(
                        onDrag: { model.edgePanel.drag(to: $0) },
                        onEnd: { model.edgePanel.endDrag() })
                }
            }
            .accessibilityLabel("Move side panel")
            .help("Drag vertically or across the screen. Release to snap to the nearest edge.")
    }

    private var summaryContent: some View {
        VStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 32, height: 32)
                .background(statusColor.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(statusColor.opacity(0.7), lineWidth: 1.5))
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.12), value: statusSymbol)
                .help(statusLabel)
                .accessibilityLabel("Hush: \(statusLabel)")

            Group {
                if SnapshotRunner.requested {
                    microphoneIcon
                } else {
                    Menu {
                        Button("Automatic") { model.pinMic(nil) }
                        Divider()
                        ForEach(model.inputDevices.filter(\.isConnected), id: \.uid) { device in
                            Button(device.name) { model.pinMic(device.uid) }
                        }
                    } label: { microphoneIcon }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
            }
            .help("Active microphone: \(model.currentMicName)")
            .accessibilityLabel("Microphone: \(model.currentMicName)")

            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 32, height: 28)
                .help("\(model.stats.todayWords.formatted()) words today · \(model.stats.totalSessions) dictations")
                .accessibilityLabel("\(model.stats.todayWords) words today")

            recordButton
            gearButton
        }
        .frame(maxHeight: .infinity)
    }

    private var microphoneIcon: some View {
        Image(systemName: microphoneSymbol)
            .font(.system(size: 14))
            .foregroundStyle(Theme.Color.textPrimary)
            .frame(width: 32, height: 32)
            .background(Theme.Color.raised, in: Circle())
    }

    private var statusSymbol: String {
        switch model.pipelineState {
        case .recording: return "waveform"
        case .processing: return "ellipsis"
        case .idle:
            if model.needsAttention || model.needsRelaunch { return "exclamationmark" }
            return model.modelsLoading ? "arrow.down" : "checkmark"
        }
    }

    private var statusColor: Color {
        if model.pipelineState != .idle { return Theme.Color.signal }
        if model.needsAttention || model.needsRelaunch { return Theme.Color.error }
        return model.modelsLoading ? Theme.Color.warn : Theme.Color.ok
    }

    private var microphoneSymbol: String {
        if model.currentMicName.localizedCaseInsensitiveContains("airpods") { return "airpodspro" }
        if model.currentMicName.localizedCaseInsensitiveContains("macbook") { return "laptopcomputer" }
        return "mic.fill"
    }

    private var statusLabel: String {
        switch model.pipelineState {
        case .recording: return "RECORDING"
        case .processing: return "PROCESSING"
        case .idle: break
        }
        if model.modelsFailed { return "MODEL FAILED" }
        if model.missingPermissionCount > 0 || model.needsRelaunch { return "NEEDS ACCESS" }
        if model.modelsLoading { return "LOADING" }
        return "READY"
    }

    private var statusLevel: StatusDot.Level {
        if model.pipelineState != .idle { return .warn }
        if model.needsAttention || model.needsRelaunch { return .error }
        if model.modelsLoading { return .idle }
        return .ok
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(level: statusLevel, text: "")
                Text(statusLabel)
                    .font(Theme.Font.label())
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(model.currentMicName)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .help(model.currentMicName)
            HStack(alignment: .firstTextBaseline) {
                Text(model.stats.todayWords.formatted(.number))
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(model.stats.todayWords)))
                    .animation(Theme.Motion.response(reduceMotion), value: model.stats.todayWords)
                    .font(Theme.Font.data(32))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("words today")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            DotMatrix(columns: weekFractions, rows: 5, dot: 6, gap: 5,
                      hotColumns: [6])
                .frame(height: 50)
                .accessibilityLabel("Dictation activity over the last seven days")
            VStack(spacing: 0) {
                statRow("WPM", String(format: "%.0f", model.stats.spokenWPM))
                statRow("TIME SAVED", HomeView.timeSaved(model.stats.timeSavedSeconds))
                statRow("STREAK", model.streakDays == 1 ? "1 day" : "\(model.streakDays) days")
                statRow("DICTATIONS", model.stats.totalSessions.formatted(.number))
            }
            HStack {
                recordButton
                Spacer()
                gearButton
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Last 7 days (oldest → today) as 0…1 lit fractions of 5 rows.
    private var weekFractions: [Double] {
        let calendar = Calendar.current
        let today = Date()
        var words: [Int] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today)
            else { words.append(0); continue }
            words.append(model.wordsPerDay[HomeView.dayKey(day)] ?? 0)
        }
        let top = Double(words.max() ?? 0)
        guard top > 0 else { return [Double](repeating: 0, count: 7) }
        return words.map { $0 == 0 ? 0 : max(0.2, Double($0) / top) }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Color.hairline)
                .frame(height: 1)
            HStack {
                Text(label).tileLabel()
                Spacer()
                Text(value)
                    .font(Theme.Font.data())
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.vertical, 5)
        }
    }

    /// 36pt signal circle — mic glyph idle, stop square while recording.
    private var recordDisabled: Bool {
        model.pipelineState != .recording &&
            (model.pipelineState == .processing || model.modelsLoading || model.needsAttention || model.needsRelaunch)
    }

    private var recordButton: some View {
        Button {
            model.toggleDictation()
        } label: {
            Image(systemName: model.pipelineState == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.window)
                .frame(width: isExpanded ? 36 : 32, height: isExpanded ? 36 : 32)
                .background(Theme.Color.signal, in: Circle())
        }
        .buttonStyle(HushIconButtonStyle())
        .disabled(recordDisabled)
        .opacity(recordDisabled ? 0.45 : 1)
        .accessibilityLabel(model.pipelineState == .recording ? "Stop dictation" : "Start dictation")
    }

    private var gearButton: some View {
        Button {
            model.openMainWindow(page: .settings)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: isExpanded ? 28 : 24, height: isExpanded ? 28 : 24)
                .background(Theme.Color.raised, in: Circle())
                .overlay(Circle().stroke(Theme.Color.hairline, lineWidth: 1))
        }
        .buttonStyle(HushIconButtonStyle())
        .accessibilityLabel("Settings")
    }
}

private struct SidePanelDragHandle: NSViewRepresentable {
    var onDrag: (NSPoint) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.setAccessibilityLabel("Move side panel")
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onDrag: (NSPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            onDrag(NSEvent.mouseLocation)
        }
        override func mouseDragged(with event: NSEvent) { onDrag(NSEvent.mouseLocation) }
        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            onEnd()
        }
    }
}
