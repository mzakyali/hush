import AppKit
import SwiftUI

/// Main window (DESIGN.md): 1000 × 680 default, 860 × 580 min,
/// `.fullSizeContentView` with a transparent titlebar — traffic lights
/// float over the sidebar.
@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let model: AppModel
    private let nav = PageNavigator()

    init(model: AppModel) {
        self.model = model
    }

    /// Switch the sidebar selection — applied to the live window on `show()`.
    func navigate(to page: MainPage) {
        nav.page = page
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = Self.makeWindow(model: model, nav: nav)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shared by `show()` and snapshot rendering — identical chrome + content.
    static func makeWindow(model: AppModel, nav: PageNavigator? = nil,
                           page: MainPage = .home,
                           expandedID: String? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Hush"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 860, height: 580)
        window.contentView = NSHostingView(
            rootView: MainWindowView(model: model, nav: nav, initialPage: page,
                                     initialExpandedID: expandedID))
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        return window
    }
}
