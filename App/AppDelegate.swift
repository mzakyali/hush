import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        // MenuBarExtra content is lazy — kick the model + window from here.
        Task { @MainActor in
            let model = SharedAppModel.model
            model.start()
            if !SnapshotRunner.requested { model.openMainWindow() }
        }
    }

    /// Clicking the Dock icon reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in SharedAppModel.model.openMainWindow() }
        }
        return true
    }

    /// Remove the Control Strip item + any modal Touch Bar so no ghost
    /// item is left behind in TouchBarServer.
    func applicationWillTerminate(_ notification: Notification) {
        SharedAppModel.model.touchBar.teardown()
    }

    func applyActivationPolicy() {
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
