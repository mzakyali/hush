import AppKit
import HushCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.pipelineState == .recording
             ? "● Recording"
             : model.pipelineState == .processing ? "Processing…" : "Idle")
        statusLine("Speech", state: model.whisperStatus)
        statusLine("Cleanup", state: model.cleanupStatus)
        if model.modelsFailed {
            Button("Retry model load") { model.prepareModels() }
        }
        if let error = model.lastError {
            Text(error).foregroundStyle(.red)
        }
        Divider()
        // §4a: Automatic + connected devices; a pick pins the device until it
        // disconnects or Automatic is chosen again.
        Menu("Microphone") {
            Button {
                model.pinMic(nil)
            } label: {
                if model.micStore.pinnedUID == nil {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }
            Divider()
            ForEach(model.inputDevices.filter(\.isConnected), id: \.uid) { device in
                Button {
                    model.pinMic(device.uid)
                } label: {
                    if model.micStore.pinnedUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        }
        Divider()
        Button("Open Hush") {
            model.openMainWindow()
        }
        Divider()
        Button("Quit Hush") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func statusLine(_ name: String, state: ModelLoadState) -> some View {
        HStack(spacing: 4) {
            if case .optimizing(let startedAt) = state {
                Text("\(name): \(state.label)")
                Text(startedAt, style: .timer)
            } else {
                Text("\(name): \(state.label)")
            }
        }
        .foregroundStyle(.secondary)
    }
}
