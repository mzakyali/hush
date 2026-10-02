import AppKit
import AudioCapture
import HushCore
import ServiceManagement
import SwiftUI

/// Settings (DESIGN.md): native grouped Form in dark appearance.
/// Sections: General / Microphone / Shortcuts / Models / Privacy / Permissions.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var confirmDeleteAll = false
    @State private var confirmResetStats = false
    @State private var modelStorageBytes: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Settings")
            Form {
                general
                microphone
                shortcuts
                models
                privacy
                permissions
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .padding(Theme.Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { modelStorageBytes = Self.directorySize(AppPaths().models) }
    }

    // MARK: - sections

    private var general: some View {
        Section("General") {
            // Dock / menu bar / side panel — at least one must stay on,
            // so the toggle that would remove the last surface is disabled.
            Toggle("Show side panel", isOn: $model.showSidePanel)
                .disabled(model.showSidePanel && !model.showInMenuBar && !model.showInDock)
            Toggle("Sliver when idle", isOn: $model.sidePanelSliver)
                .disabled(!model.showSidePanel)
            Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                .disabled(model.showInMenuBar && !model.showSidePanel && !model.showInDock)
            Toggle("Show in Dock", isOn: $model.showInDock)
                .disabled(model.showInDock && !model.showSidePanel && !model.showInMenuBar)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
    }

    // MARK: - Microphone (spec §4a)

    /// Picker binding: nil tag = Automatic; a device UID pins it.
    private var micPin: Binding<String?> {
        Binding(
            get: { model.micStore.pinnedUID },
            set: { model.pinMic($0) }
        )
    }

    private var microphone: some View {
        Section("Microphone") {
            LabeledContent {
                Picker("Input", selection: micPin) {
                    Text("Automatic (\(model.resolvedMicName ?? "system default"))")
                        .tag(String?.none)
                    ForEach(model.inputDevices.filter(\.isConnected), id: \.uid) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("Input")
            }

            // Priority list — every device Hush has seen; disconnected ones
            // keep their place, greyed out. Drag to reorder.
            List {
                ForEach(model.inputDevices, id: \.uid) { device in
                    micPriorityRow(device)
                }
                .onMove { model.moveMic(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(model.inputDevices.count) * 30 + 10)

            Text("Using AirPods as the mic switches them to the Bluetooth call profile, which lowers playback quality — keep them low priority.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    private func micPriorityRow(_ device: InputDevice) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Color.textTertiary)
            Text(device.name)
                .font(Theme.Font.body)
                .foregroundStyle(device.isConnected
                                 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
            Spacer()
            if !device.isConnected {
                Text("DISCONNECTED")
                    .tileLabel()
                    .foregroundStyle(Theme.Color.textTertiary)
            } else if model.micStore.resolvedUID() == device.uid {
                Text("IN USE")
                    .tileLabel()
                    .foregroundStyle(Theme.Color.signal)
            }
        }
    }

    private var shortcuts: some View {
        Section("Shortcuts") {
            LabeledContent {
                HStack(spacing: Theme.Space.xs) { Keycap(legend: "fn") }
            } label: { Text("Hold to talk") }
            LabeledContent {
                HStack(spacing: Theme.Space.xs) { Keycap(legend: "⌥"); Keycap(legend: "⌥") }
            } label: { Text("Toggle") }
            LabeledContent {
                HStack(spacing: Theme.Space.xs) { Keycap(legend: "esc") }
            } label: { Text("Cancel") }
            LabeledContent {
                HStack(spacing: Theme.Space.xs) {
                    Keycap(legend: "⌃"); Keycap(legend: "⌥"); Keycap(legend: "Z")
                }
            } label: { Text("Paste raw") }
        }
    }

    private var models: some View {
        Section("Models") {
            LabeledContent {
                HStack(spacing: Theme.Space.s) {
                    Text(model.whisperStatus.label)
                    if case .failed = model.whisperStatus {
                        Button("Retry") { model.prepareModels() }
                            .buttonStyle(.hushSecondary)
                    }
                }
            } label: { Text("Speech — Whisper large-v3 turbo") }
            LabeledContent {
                HStack(spacing: Theme.Space.s) {
                    Text(model.cleanupStatus.label)
                    if case .failed = model.cleanupStatus {
                        Button("Retry") { model.prepareModels() }
                            .buttonStyle(.hushSecondary)
                    }
                }
            } label: { Text("Cleanup — Qwen3 4B") }
            LabeledContent("Storage used") {
                Text(Self.byteString(modelStorageBytes))
                    .font(Theme.Font.data())
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            Stepper("Keep history for \(model.retentionDays) days",
                    value: $model.retentionDays, in: 1...365)
            Button("Delete all history…", role: .destructive) {
                confirmDeleteAll = true
            }
            .confirmationDialog(
                "Delete all dictation history?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete all history", role: .destructive) {
                    model.deleteAllHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every saved dictation and its audio is deleted permanently. Aggregate statistics are kept.")
            }
            Button("Reset statistics…", role: .destructive) {
                confirmResetStats = true
            }
            .confirmationDialog(
                "Reset all statistics?",
                isPresented: $confirmResetStats,
                titleVisibility: .visible
            ) {
                Button("Reset statistics", role: .destructive) {
                    model.resetStatistics()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Word counts, sessions and speaking-time aggregates are cleared. Dictation history is kept.")
            }
        }
    }

    private var permissions: some View {
        Section("Permissions") {
            permissionRow("Microphone", granted: model.permissions.mic, pane: .microphone)
            permissionRow("Accessibility", granted: model.permissions.accessibility, pane: .accessibility)
            permissionRow("Input Monitoring", granted: model.permissions.inputMonitoring, pane: .inputMonitoring)
            if model.needsRelaunch {
                Button("Restart Hush") { model.relaunch() }
                    .buttonStyle(.hushPrimary)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool,
                               pane: AppModel.PrivacyPane) -> some View {
        LabeledContent {
            HStack(spacing: Theme.Space.s) {
                StatusDot(level: granted ? .ok : .warn, text: "")
                if !granted {
                    Button("Allow") { model.requestPermission(pane) }
                        .buttonStyle(.hushSecondary)
                }
            }
        } label: {
            Text(name)
        }
    }

    // MARK: - helpers

    static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    static func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
