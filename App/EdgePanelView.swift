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

/// Panel geometry shared by the view and the controller's hit-test.
///
/// The window stays at `window` size while the panel is visible — the card
/// morphs out of the resting rail inside it — so the frame is only touched
/// on drag, dock, screen change and show. `margin` is transparent headroom
/// for the shadow; for an attached panel the shape's flush edge lands at
/// `margin` inside the window.
enum EdgePanelLayout {
    static let margin: CGFloat = 24
    /// The expanded card.
    static let card = CGSize(width: 240, height: 424)
    /// Resting rail — status ring + record button.
    static let rail = CGSize(width: 32, height: 112)
    /// "Sliver when idle" — a hairline flush to the edge.
    static let sliver = CGSize(width: 6, height: 64)
    static let window = CGSize(width: card.width + 2 * margin,
                               height: card.height + 2 * margin)

    static func collapsedSize(sliver: Bool) -> CGSize { sliver ? self.sliver : rail }

    /// Concave-fillet (cx/cy) and corner (rx/ry) radii per size, plus the
    /// corner radius for the floating card. `cx + rx ≤ w` — equal means the
    /// top/bottom edges are zero-length and the silhouette is all fillet.
    static func radii(expanded: Bool, sliver: Bool)
        -> (cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, corner: CGFloat) {
        if expanded { return (18, 18, 22, 22, 24) }
        return sliver ? (3, 6, 3, 6, 3) : (10, 18, 10, 18, 16)
    }

    /// The shape's rect inside the fixed window. `railCenterY` is the resting
    /// rail's vertical centre in window coordinates (y-down); the card always
    /// centres itself in the window.
    static func shapeRect(expanded: Bool, sliver: Bool,
                          attachment: SidePanelAttachment,
                          railCenterY: CGFloat,
                          in window: CGSize = Self.window) -> CGRect {
        let size = expanded ? card : collapsedSize(sliver: sliver)
        let midY = expanded ? window.height / 2 : railCenterY
        let x: CGFloat = switch attachment {
        case .right: window.width - margin - size.width
        case .left: margin
        case .floating: (window.width - size.width) / 2
        }
        return CGRect(x: x, y: midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The silhouette in window coordinates — fill AND hit-test area.
    static func path(expanded: Bool, sliver: Bool,
                     attachment: SidePanelAttachment,
                     railCenterY: CGFloat,
                     in window: CGSize = Self.window) -> Path {
        let rect = shapeRect(expanded: expanded, sliver: sliver,
                             attachment: attachment,
                             railCenterY: railCenterY, in: window)
        let r = radii(expanded: expanded, sliver: sliver)
        if attachment == .floating {
            return RoundedRectangle(cornerRadius: r.corner, style: .continuous)
                .path(in: rect)
        }
        let path = EdgeTabShape(w: rect.width,
                                h: rect.height - 2 * (r.cy + r.ry),
                                cx: r.cx, cy: r.cy, rx: r.rx, ry: r.ry)
            .path(in: rect)
        if attachment == .left {
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                  tx: rect.minX + rect.maxX,
                                                  ty: 0))
        }
        return path
    }
}

/// The side panel's content, laid out inside the fixed-size window. The
/// silhouette and content morph between the resting rail and the expanded
/// card entirely in SwiftUI — the controller never resizes the window.
struct EdgePanelView: View {
    @ObservedObject var model: AppModel
    /// `edgeExpanded`/`edgeAttachment`/`railCenterY` — a focused feed so drag
    /// and morph frames re-render only this view.
    @ObservedObject var geometry: SidePanelGeometry
    /// Snapshot forcing.
    var forceExpanded = false
    var forceAttachment: SidePanelAttachment?
    var forceSliver = false

    @HushReducedMotion private var reduceMotion

    private var sliverMode: Bool { model.sidePanelSliver || forceSliver }
    private var isExpanded: Bool { geometry.edgeExpanded || forceExpanded }
    private var attachment: SidePanelAttachment { forceAttachment ?? geometry.edgeAttachment }

    var body: some View {
        GeometryReader { geo in
            let win = geo.size
            let railY = geometry.railCenterY ?? win.height / 2
            let collapsedRect = EdgePanelLayout.shapeRect(
                expanded: false, sliver: sliverMode,
                attachment: attachment, railCenterY: railY, in: win)
            let cardRect = EdgePanelLayout.shapeRect(
                expanded: true, sliver: sliverMode,
                attachment: attachment, railCenterY: railY, in: win)
            let shapeRect = isExpanded ? cardRect : collapsedRect
            ZStack {
                silhouette
                    .frame(width: shapeRect.width, height: shapeRect.height)
                    .shadow(color: .black.opacity(0.35), radius: 18,
                            x: attachment == .right ? -4
                              : attachment == .left ? 4 : 0)
                    .position(x: shapeRect.midX, y: shapeRect.midY)

                collapsedContent
                    .frame(width: collapsedRect.width, height: collapsedRect.height)
                    .position(x: collapsedRect.midX, y: collapsedRect.midY)
                    .opacity(isExpanded ? 0 : 1)
                    .allowsHitTesting(!isExpanded)

                expandedContent
                    .frame(width: cardRect.width, height: cardRect.height)
                    .position(x: cardRect.midX, y: cardRect.midY)
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
            }
            .animation(reduceMotion ? nil : Theme.Motion.spring, value: isExpanded)
            .animation(Theme.Motion.response(reduceMotion), value: geometry.railCenterY)
        }
        .preferredColorScheme(.dark)
    }

    /// The black silhouette — one EdgeTabShape whose radii interpolate
    /// through the morph; a rounded card while floating.
    @ViewBuilder private var silhouette: some View {
        let r = EdgePanelLayout.radii(expanded: isExpanded, sliver: sliverMode)
        let size = isExpanded ? EdgePanelLayout.card
                              : EdgePanelLayout.collapsedSize(sliver: sliverMode)
        if attachment == .floating {
            RoundedRectangle(cornerRadius: r.corner, style: .continuous)
                .fill(Color.black)
        } else {
            EdgeTabShape(w: size.width,
                         h: size.height - 2 * (r.cy + r.ry),
                         cx: r.cx, cy: r.cy, rx: r.rx, ry: r.ry)
                .fill(Color.black)
                .scaleEffect(x: attachment == .left ? -1 : 1)
        }
    }

    // MARK: - collapsed rail / sliver

    /// The whole rail is the drag surface — a 4 pt movement threshold keeps
    /// taps on the record button firing.
    private var railDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in model.edgePanel.drag(to: NSEvent.mouseLocation) }
            .onEnded { _ in model.edgePanel.endDrag() }
    }

    private var collapsedContent: some View {
        Group {
            if sliverMode {
                Capsule(style: .continuous)
                    .fill(statusColor)
                    .frame(width: 2, height: 52)
                    .animation(Theme.Motion.hover, value: statusColor)
            } else {
                VStack(spacing: 10) {
                    statusRing
                    recordButton(diameter: 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(railDrag)
        .accessibilityElement(children: .contain)
    }

    /// 12 pt status ring — same colour semantics as the card's StatusDot.
    /// No symbol effects; colour/opacity transitions only.
    private var statusRing: some View {
        Circle()
            .strokeBorder(statusColor.opacity(0.9), lineWidth: 1.5)
            .background(statusColor.opacity(0.16), in: Circle())
            .frame(width: 12, height: 12)
            .animation(Theme.Motion.hover, value: statusColor)
            .help(statusLabel)
            .accessibilityLabel("Hush: \(statusLabel)")
    }

    private var statusColor: Color {
        if model.pipelineState != .idle { return Theme.Color.signal }
        if model.needsAttention || model.needsRelaunch { return Theme.Color.error }
        return model.modelsLoading ? Theme.Color.warn : Theme.Color.ok
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

    // MARK: - expanded card

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            dragHandle
            HStack(spacing: 8) {
                StatusDot(level: statusLevel, text: "")
                Text(statusLabel)
                    .font(Theme.Font.label())
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .help("\(model.stats.todayWords.formatted()) words today · \(model.stats.totalSessions) dictations")
            }
            micRow
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
            VStack(spacing: 4) {
                DotMatrix(columns: weekFractions, rows: 5, dot: 6, gap: 5,
                          hotColumns: [6])
                    .frame(width: 72, height: 50)
                weekdayStrip
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictation activity over the last seven days")
            VStack(spacing: 0) {
                statRow("WPM", String(format: "%.0f", model.stats.spokenWPM))
                statRow("TIME SAVED", HomeView.timeSaved(model.stats.timeSavedSeconds))
                statRow("STREAK", model.streakDays == 1 ? "1 day" : "\(model.streakDays) days")
                statRow("DICTATIONS", model.stats.totalSessions.formatted(.number))
            }
            // §6: pending edit suggestions — click opens the Dictionary page.
            if !model.pendingSuggestions.isEmpty {
                suggestionsRow
            }
            Spacer(minLength: 0)
            HStack {
                recordButton(diameter: 36)
                Spacer()
                gearButton
            }
        }
        // The card's flat top edge sits `cy` (18 pt) below the silhouette
        // bounds and the flat bottom edge `cy` above; the handle rides ~8 pt
        // under the top edge and the footer ~16 pt above the bottom edge,
        // clear of the concave fillets.
        .padding(EdgeInsets(top: 26, leading: 16, bottom: 34, trailing: 16))
    }

    /// Single-letter weekday labels under the dot matrix, one per column —
    /// oldest → today (the rightmost, in signal). Geist Mono 9 pt.
    private var weekdayStrip: some View {
        // DotMatrix pitch = dot 6 + gap 5 = 11; letters are centred under
        // their column (label frames are 11 wide, dots start 2.5 pt in).
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdayLetter(column: i))
                    .font(Theme.Font.label(9))
                    .foregroundStyle(i == 6 ? Theme.Color.signal : Theme.Color.textTertiary)
                    .frame(width: 11)
            }
        }
        .frame(width: 72)
        .offset(x: -2.5)
    }

    private func weekdayLetter(column: Int) -> String {
        guard let day = Calendar.current.date(byAdding: .day, value: column - 6,
                                              to: Date()) else { return "" }
        let weekday = Calendar.current.component(.weekday, from: day)
        let symbol = Calendar.current.veryShortWeekdaySymbols[weekday - 1]
        return String(symbol.prefix(1))
    }

    /// Mic device row — `mic` + name + chevron, opens the pin menu.
    private var micRow: some View {
        Group {
            if SnapshotRunner.requested {
                micRowLabel
            } else {
                Menu {
                    Button("Automatic") { model.pinMic(nil) }
                    if model.inputDevices.contains(where: \.isConnected) {
                        Divider()
                    }
                    ForEach(model.inputDevices.filter(\.isConnected), id: \.uid) { device in
                        Button { model.pinMic(device.uid) } label: {
                            if model.micStore.pinnedUID == device.uid {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: { micRowLabel }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            }
        }
        .help("Active microphone: \(model.currentMicName)")
        .accessibilityLabel("Microphone: \(model.currentMicName)")
    }

    private var micRowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic")
                .font(.system(size: 10))
            Text(model.currentMicName)
                .font(Theme.Font.data(11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.Color.raised.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
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

    /// "N suggestions →" row — compact, signal-tinted count, opens Dictionary.
    private var suggestionsRow: some View {
        Button { model.openDictionary() } label: {
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.signal)
                Text(model.pendingSuggestions.count == 1
                     ? "1 suggestion — review"
                     : "\(model.pendingSuggestions.count) suggestions — review")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.Color.signalSoft.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edits you made after pasting — approve to teach Hush")
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
            .padding(.vertical, 4)
        }
    }

    private var recordDisabled: Bool {
        model.pipelineState != .recording &&
            (model.pipelineState == .processing || model.modelsLoading || model.needsAttention || model.needsRelaunch)
    }

    private func recordButton(diameter: CGFloat) -> some View {
        Button {
            model.toggleDictation()
        } label: {
            Image(systemName: model.pipelineState == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(Theme.Color.window)
                .frame(width: diameter, height: diameter)
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
                .frame(width: 28, height: 28)
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
