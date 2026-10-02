import AppKit
import SwiftUI

private struct HushReducedMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var hushReducedMotion: Bool? {
        get { self[HushReducedMotionKey.self] }
        set { self[HushReducedMotionKey.self] = newValue }
    }
}

/// Uses the system preference; previews may supply an explicit alternative.
@propertyWrapper
struct HushReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.hushReducedMotion) private var override
    var wrappedValue: Bool { override ?? system }
}

/// DESIGN.md tokens — the "instrument panel" world. Dark only.
enum Theme {
    enum Color {
        static let window      = SwiftUI.Color(hb: 0x0B0B0C)
        static let tile        = SwiftUI.Color(hb: 0x161618)
        static let raised      = SwiftUI.Color(hb: 0x1F1F22)
        static let hairline    = SwiftUI.Color.white.opacity(0.07)
        static let textPrimary = SwiftUI.Color(hb: 0xF2F0EC)
        static let textSecondary = SwiftUI.Color.white.opacity(0.62)
        static let textTertiary  = SwiftUI.Color.white.opacity(0.40)
        static let dotOff      = SwiftUI.Color.white.opacity(0.09)
        static let signal      = SwiftUI.Color(hb: 0xFF5B2E)
        static let signalSoft  = signal.opacity(0.22)
        static let ok          = SwiftUI.Color(hb: 0x3DDC84)
        static let warn        = SwiftUI.Color(hb: 0xFFB020)
        static let error       = SwiftUI.Color(hb: 0xFF6B6B)
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let huge: CGFloat = 48
        static let tilePadding: CGFloat = 20
        static let gridGap: CGFloat = 12
        static let contentPadding: CGFloat = 32
    }

    enum Radius {
        static let tile: CGFloat = 16
        static let control: CGFloat = 8
        static let keycap: CGFloat = 6
        static let heatCell: CGFloat = 3
    }

    enum Motion {
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let hover = Animation.easeOut(duration: 0.12)
        static func response(_ reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82)
        }
        static func navigation(_ reduced: Bool) -> Animation {
            reduced ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.88)
        }
    }

    enum Font {
        /// Instrument Serif — Home hero number only.
        static func display(_ size: CGFloat = 56) -> SwiftUI.Font {
            .custom("InstrumentSerif-Regular", size: size, relativeTo: .largeTitle)
        }
        /// Geist Mono — labels (Medium, +0.06em, uppercase) and data readouts.
        static func label(_ size: CGFloat = 11) -> SwiftUI.Font {
            .custom("GeistMono-Medium", size: size, relativeTo: .caption)
        }
        static func data(_ size: CGFloat = 13) -> SwiftUI.Font {
            .custom("GeistMono-Regular", size: size, relativeTo: .body)
        }
        static let dataLg = SwiftUI.Font.custom("GeistMono-Regular", size: 20, relativeTo: .title3)
        // SF Pro roles — system fonts.
        static let title   = SwiftUI.Font.system(size: 22, weight: .semibold, design: .default)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body    = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 12)
    }
}

extension SwiftUI.Color {
    init(hb hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension View {
    /// Uppercase `label` tile header.
    func tileLabel() -> some View {
        font(Theme.Font.label())
            .tracking(0.06 * 11)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Color.textTertiary)
    }

    /// 2pt signal at 60%, offset 2 — the keyboard focus ring.
    func hushFocusRing(_ focused: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                .strokeBorder(Theme.Color.signal.opacity(0.6), lineWidth: 2)
                .padding(-4)
                .opacity(focused ? 1 : 0)
        }
    }
}
