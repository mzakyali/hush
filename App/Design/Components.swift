import SwiftUI

/// Tile — the only container. `surface.tile`, radius 16, padding 20.
/// Header: uppercase `label` left, optional trailing accessory.
struct Tile<Content: View, Accessory: View>: View {
    var label: String
    /// Stretch to the tallest sibling in the grid row (content stays top).
    var fillHeight = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ label: String, fillHeight: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.fillHeight = fillHeight
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(label).tileLabel()
                Spacer()
                accessory()
            }
            content()
            if fillHeight { Spacer(minLength: 0) }
        }
        .padding(Theme.Space.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil,
               alignment: .topLeading)
        .background(Theme.Color.tile, in: RoundedRectangle(cornerRadius: Theme.Radius.tile))
    }
}

/// Dot matrix primitive — a grid of round dots, each off / lit / signal-hot.
/// Rendered with `Canvas` (no per-dot views).
struct DotMatrix: View, Animatable {
    @HushReducedMotion private var reduceMotion
    nonisolated var animatableData: MotionVector {
        get { MotionVector(values: columns) }
        set { columns = newValue.values }
    }

    /// rows × columns occupancy: `columns[c]` = 0…1 fraction of rows lit (bottom-up).
    var columns: [Double]
    var rows: Int = 5
    var dot: CGFloat = 3.5
    var gap: CGFloat = 2.5
    /// Column indexes lit in `signal` instead of `text.primary`.
    var hotColumns: Set<Int> = []

    var body: some View {
        Canvas { ctx, size in
            let pitch = dot + gap
            let cols = columns.count
            let w = CGFloat(cols) * pitch - gap
            let h = CGFloat(rows) * pitch - gap
            let ox = (size.width - w) / 2
            let oy = (size.height - h) / 2
            for c in 0..<cols {
                let level = columns[c] * Double(rows)
                for r in 0..<rows {
                    let rect = CGRect(x: ox + CGFloat(c) * pitch,
                                      y: oy + h - CGFloat(r) * pitch - dot,
                                      width: dot, height: dot)
                    let path = Path(ellipseIn: rect)
                    let coverage = min(1, max(0, level - Double(r)))
                    ctx.fill(path, with: .color(Theme.Color.dotOff))
                    let color = hotColumns.contains(c) ? Theme.Color.signal : Theme.Color.textPrimary
                    ctx.fill(path, with: .color(color.opacity(coverage)))
                }
            }
        }
        .animation(Theme.Motion.response(reduceMotion), value: columns)
    }
}

/// Keycap — `surface.raised`, radius 6, height 22, pad 7, `data` 12,
/// 1px bottom inner shade black 40%.
struct Keycap: View {
    var legend: String

    var body: some View {
        Text(legend)
            .font(Theme.Font.data(12))
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: Theme.Radius.keycap)
                        .fill(Theme.Color.raised)
                    RoundedRectangle(cornerRadius: Theme.Radius.keycap)
                        .fill(Color.black.opacity(0.40))
                        .frame(height: 1)
                }
            )
            .fixedSize()
    }
}

/// Status dot — 6pt circle + caption. ok / warn / error / tertiary(idle).
struct StatusDot: View {
    enum Level: Equatable { case ok, warn, error, idle }
    @HushReducedMotion private var reduceMotion
    var level: Level
    var text: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .animation(Theme.Motion.response(reduceMotion), value: level)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var color: Color {
        switch level {
        case .ok: Theme.Color.ok
        case .warn: Theme.Color.warn
        case .error: Theme.Color.error
        case .idle: Theme.Color.textTertiary
        }
    }
}

/// Heatmap — 12×7 cells of 12×12, radius 3, gap 3.
/// Levels: 0 dot.off; 1 signal 22% + 45° hatch; 2 signal 45%; 3 signal 70%; 4 signal.
struct Heatmap: View {
    /// levels[col][row], row 0 = bottom (or whatever caller provides).
    var levels: [[Int]]
    var today: (col: Int, row: Int)? = nil
    var cell: CGFloat = 12
    var gap: CGFloat = 3

    var body: some View {
        Canvas { ctx, size in
            let pitch = cell + gap
            let w = CGFloat(levels.count) * pitch - gap
            let ox = (size.width - w) / 2
            for (c, col) in levels.enumerated() {
                for (r, level) in col.enumerated() {
                    let rect = CGRect(x: ox + CGFloat(c) * pitch,
                                      y: CGFloat(r) * pitch,
                                      width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: Theme.Radius.heatCell)
                    switch level {
                    case 1:
                        ctx.fill(path, with: .color(Theme.Color.signalSoft))
                        // 45° hatch lines, 1pt, signal 50%
                        var hatch = Path()
                        let bound = rect.insetBy(dx: -rect.height, dy: -rect.height)
                        var x = bound.minX
                        while x < bound.maxX + bound.height {
                            hatch.move(to: CGPoint(x: x, y: rect.maxY))
                            hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                            x += 3.5
                        }
                        ctx.clip(to: path)
                        ctx.stroke(hatch, with: .color(Theme.Color.signal.opacity(0.5)), lineWidth: 1)
                    case 2:
                        ctx.fill(path, with: .color(Theme.Color.signal.opacity(0.45)))
                    case 3:
                        ctx.fill(path, with: .color(Theme.Color.signal.opacity(0.70)))
                    case 4:
                        ctx.fill(path, with: .color(Theme.Color.signal))
                    default:
                        ctx.fill(path, with: .color(Theme.Color.dotOff))
                    }
                    if let today, today.col == c, today.row == r {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        cornerRadius: Theme.Radius.heatCell),
                                   with: .color(Theme.Color.textPrimary), lineWidth: 1)
                    }
                }
            }
        }
    }
}

/// History list row — 44pt+; time `data` 12 tertiary (44pt column),
/// app icon 16pt, single-line text; hover reveals Copy/Play buttons.
struct HistoryRow: View {
    var time: String
    var appName: String?
    var appIcon: Image?
    var text: String
    var isExpanded: Bool
    var onCopy: () -> Void
    var onPlay: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?
    @HushReducedMotion private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(time)
                .font(Theme.Font.data(12))
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 44, alignment: .leading)
            if let appIcon {
                appIcon
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(width: 16, height: 16)
            }
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if hovering || isExpanded {
                Button {
                    onCopy()
                    copyTask?.cancel()
                    copied = true
                    copyTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HushGhostButtonStyle())
                .accessibilityLabel(copied ? "Copied" : "Copy")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HushGhostButtonStyle())
                .accessibilityLabel("Play")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 44)
        .background(isExpanded ? Theme.Color.raised : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.response(reduceMotion), value: hovering)
        .animation(Theme.Motion.response(reduceMotion), value: copied)
        .onDisappear { copyTask?.cancel() }
    }
}

/// Wrapping flow of subviews — the History expanded card's cleaned text as
/// individually selectable/menu-able words.
struct WordsFlow: Layout {
    var spacing: CGFloat = 0
    var rowSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Button styles

/// Primary — `signal` fill, dark text, 28 tall, radius 8.
struct HushPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @HushReducedMotion private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body.weight(.semibold))
            .foregroundStyle(Theme.Color.window)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.Color.signal.opacity(isEnabled ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.94 : hovering ? 1.025 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.response(reduceMotion), value: configuration.isPressed)
            .animation(Theme.Motion.response(reduceMotion), value: hovering)
    }
}

/// Secondary — `surface.raised` fill, primary text.
struct HushSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @HushReducedMotion private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.Color.raised,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .brightness(hovering && isEnabled ? 0.04 : 0)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.95 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.response(reduceMotion), value: configuration.isPressed)
            .animation(Theme.Motion.hover, value: hovering)
    }
}

/// Ghost/icon — transparent, white 6% hover.
struct HushGhostButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @HushReducedMotion private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.Color.textSecondary)
            .background(Color.white.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.9 : hovering ? 1.06 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.response(reduceMotion), value: configuration.isPressed)
    }
}

struct HushIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @HushReducedMotion private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.88 : hovering ? 1.08 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.response(reduceMotion), value: hovering)
            .animation(Theme.Motion.response(reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HushPrimaryButtonStyle {
    static var hushPrimary: HushPrimaryButtonStyle { .init() }
}
extension ButtonStyle where Self == HushSecondaryButtonStyle {
    static var hushSecondary: HushSecondaryButtonStyle { .init() }
}
extension ButtonStyle where Self == HushGhostButtonStyle {
    static var hushGhost: HushGhostButtonStyle { .init() }
}
