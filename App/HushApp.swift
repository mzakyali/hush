import AppKit
import SwiftUI

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The side panel is the primary affordance; the menu-bar extra is
    // optional and off by default (Settings → General). AppStorage (not the
    // model's @Published) — a scene-level ObservableObject binding makes the
    // MenuBarExtra graph re-evaluate on every model change.
    @AppStorage("showInMenuBar") private var showInMenuBar = false

    var body: some Scene {
        MenuBarExtra("Hush", image: "MenuBarIcon", isInserted: $showInMenuBar) {
            MenuBarView(model: SharedAppModel.model)
                .task { SharedAppModel.model.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}
