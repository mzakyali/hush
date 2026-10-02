import AppKit
import AudioCapture
import HushCore
import Store
import SwiftUI

/// Debug-only offscreen rendering: `Hush --render-snapshots <dir>` renders
/// the screens + overlay states to PNGs at 2× using an in-memory store
/// seeded with fake data, then exits.
@MainActor
enum SnapshotRunner {
    static var requested: Bool {
        CommandLine.arguments.contains("--render-snapshots")
    }

    private static var outputDirectory: URL {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-snapshots"), i + 1 < args.count else {
            return URL(fileURLWithPath: "spike/ui-snapshots")
        }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func renderAll(model: AppModel) async {
        let dir = outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if CommandLine.arguments.contains("--verify-side-panel"),
           !(await SidePanelVerification.run(model: model)) { exit(1) }

        model.whisperStatus = .ready
        model.cleanupStatus = .ready

        // --- empty states (before seeding) ---
        model.permissions = AppModel.Permissions()
        capturePage(.home, model: model, name: "home-empty", in: dir)
        capturePage(.history, model: model, name: "history-empty", in: dir)
        capturePage(.dictionary, model: model, name: "dictionary-empty", in: dir)

        // --- seed fake data ---
        await seed(model: model)
        await model.refreshData()
        // Pending suggestions feed Dictionary's SUGGESTIONS section and the
        // edge-expanded-suggestions variant; edge renders below start clean.
        let seededSuggestions = model.pendingSuggestions

        // Grant-access flow states — all permissions missing. Taller windows
        // so the Permissions section / System tile isn't below the fold.
        capturePage(.home, model: model, height: 840,
                    name: "home-permissions-missing", in: dir)
        capturePage(.settings, model: model, height: 1000,
                    name: "settings-permissions-missing", in: dir)

        model.permissions.mic = true
        model.permissions.accessibility = true
        model.permissions.inputMonitoring = true

        // Fake mic list: internal + AirPods connected, Yeti disconnected
        // (keeps its place in the priority order, greyed).
        seedDevices(model: model)

        capturePage(.home, model: model, name: "home-populated", in: dir)
        capturePage(.settings, model: model, name: "settings", in: dir)
        capturePage(.settings, model: model, height: 1180,
                    name: "settings-microphone", in: dir)
        capturePage(.dictionary, model: model, name: "dictionary", in: dir)
        capturePage(.styles, model: model, height: 900, name: "styles", in: dir)
        capturePage(.history, model: model,
                    expandedID: model.dictations.first?.id,
                    name: "history-populated", in: dir)
        capturePage(.history, model: model,
                    expandedID: model.dictations.first {
                        $0.cleanedText == $0.rawText
                    }?.id,
                    name: "history-expanded-unchanged", in: dir)
        capturePage(.history, model: model,
                    expandedID: model.dictations.first {
                        $0.cleanedText != $0.rawText
                    }?.id,
                    name: "history-expanded-diff", in: dir)

        // --- side panel: resting summary, details, and desktop/edge placements ---
        model.pendingSuggestions = []
        renderEdge(model: model, expanded: false, name: "edge-collapsed", in: dir)
        renderEdge(model: model, expanded: false, sliver: true, name: "edge-sliver", in: dir)
        renderEdge(model: model, expanded: true, name: "edge-expanded", in: dir)
        // §6: the "N suggestions" row variant.
        model.pendingSuggestions = seededSuggestions
        renderEdge(model: model, expanded: true, name: "edge-expanded-suggestions", in: dir)
        model.pendingSuggestions = []
        renderEdge(model: model, expanded: false, attachment: .left, name: "edge-left", in: dir)
        renderEdge(model: model, expanded: false, attachment: .floating, name: "edge-floating", in: dir)
        renderEdge(model: model, expanded: false, reducedMotion: true, name: "edge-reduced-motion", in: dir)
        model.resolvedMicName = "External USB Microphone with a Very Long Device Name"
        renderEdge(model: model, expanded: false, name: "edge-long-mic", in: dir)
        model.resolvedMicName = "MacBook Pro Microphone"
        model.whisperStatus = .loading
        renderEdge(model: model, expanded: false, name: "edge-loading", in: dir)
        model.whisperStatus = .ready
        model.permissions.mic = false
        renderEdge(model: model, expanded: false, name: "edge-needs-access", in: dir)
        model.permissions.mic = true
        model.pipelineState = .recording
        model.micName = "MacBook Pro Microphone"
        renderEdge(model: model, expanded: false, name: "edge-recording", in: dir)
        renderEdge(model: model, expanded: true, name: "edge-expanded-recording", in: dir)
        model.pipelineState = .processing
        renderEdge(model: model, expanded: false, name: "edge-processing", in: dir)
        model.pipelineState = .idle
        model.micName = nil

        // --- overlay states (rendered at the full 360 × 90 panel size) ---
        let feed = model.recording
        feed.overlayPhase = .visible
        let panel = CGSize(width: 360, height: 90)

        // Quiet: low levels → flat centre line.
        feed.overlayState = .recording
        feed.levelHistory = [Float](repeating: 0.02, count: 12)
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-recording-quiet", in: dir)

        // Loud: full-amplitude wave (newest level is what drives the wave).
        feed.levelHistory = (0..<12).map { Float(max(0.15, 1.0 - Double($0) * 0.08)) }
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-recording-loud", in: dir)

        feed.overlayState = .processing
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-processing", in: dir)

        feed.overlayState = .done
        feed.doneAt = Date().addingTimeInterval(-0.2)   // past the collapse
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-done", in: dir)

        feed.overlayState = .copied
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-copied", in: dir)

        feed.overlayState = .error("No speech")
        render(OverlayPillView(feed: feed), size: panel,
               name: "overlay-error", in: dir)

        feed.overlayState = .hidden
        feed.overlayPhase = .hidden

        // --- Touch Bar wave (plain AppKit view; no window needed) ---
        let wave = TouchBarWaveView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        wave.amplitude = 0.9
        wave.hotCenter = true
        renderView(wave, name: "touchbar-wave-recording", in: dir)
        wave.processing = true
        renderView(wave, name: "touchbar-wave-processing", in: dir)

        print("snapshots → \(dir.path)")
    }

    /// Fake dictations across today/yesterday/last week. Clearly synthetic.
    private static func seed(model: AppModel) async {
        guard let store = model.store else { return }
        let now = Date()
        let samples: [(String, String, String, String, Double)] = [
            // (cleaned, raw, app, bundleID, hoursAgo)
            // Identical raw/cleaned — the common case; History shows the
            // "NO CLEANUP NEEDED" chip instead of a duplicated block.
            ("Looks like the cache fix worked.",
             "Looks like the cache fix worked.",
             "Slack", "com.tinyspeck.slackmacgap", 0.4),
            ("Ship it — the build is green and QA signed off.",
             "um ship it the the build is green and QA signed off",
             "Slack", "com.tinyspeck.slackmacgap", 1.0),
            ("Moved the meeting to Friday at 3.",
             "move the meeting to Thursday no Friday at 3",
             "Calendar", "com.apple.iCal", 1.2),
            ("Besok deploy ke production setelah lunch.",
             "eh jadi besok kita deploy ke production ya uh after lunch",
             "Messages", "com.apple.MobileSMS", 3.5),
            ("Can you send me the report by tomorrow?",
             "can you send me the report by tomorrow",
             "Mail", "com.apple.mail", 26),
            ("CI is still red — rerunning the flaky suite.",
             "jadi CI-nya masih red uh rerun the flaky suite",
             "Terminal", "com.apple.Terminal", 27.5),
            ("Standup notes: blocker on the payments API.",
             "okay standup notes blocker on the payments API",
             "Notes", "com.apple.Notes", 74),
            ("Pushed the fix, needs one more review.",
             "pushed the fix uh needs one more review",
             "Xcode", "com.apple.dt.Xcode", 76),
        ]
        for (i, s) in samples.enumerated() {
            let audio: AudioBuffer16k? = i == 0
                ? AudioBuffer16k(samples: (0..<32000).map {
                    Float(sin(Double($0) / 50) * 0.3)
                  })
                : nil
            _ = try? await store.save(DictationInput(
                rawText: s.1, cleanedText: s.0, style: "default",
                cleanupFallback: false, durationSec: 4 + Double(i),
                appBundleID: s.3, appName: s.2, audio: audio),
                at: now.addingTimeInterval(-s.4 * 3600))
        }
        // Spread words over past weeks so the heatmap has shape.
        for week in [9, 21, 38, 60] {
            _ = try? await store.save(DictationInput(
                rawText: "synthetic seed entry for the heatmap",
                cleanedText: "Synthetic dictation sample for the activity heatmap.",
                style: "default", cleanupFallback: false,
                durationSec: 5, appBundleID: "com.apple.Notes", appName: "Notes",
                audio: nil),
                at: now.addingTimeInterval(-Double(week) * 3600))
        }
        // One style override so the Styles page shows an overrode row (↺).
        try? await store.setStyleOverride(bundleID: "com.apple.Notes",
                                          appName: "Notes", style: "casual")

        // Dictionary (§5): terms + replacements across all three sources,
        // a nonzero hit count, and two pending suggestions (§6) for the
        // SUGGESTIONS section + the edge-expanded-suggestions panel variant.
        _ = try? await store.addTerm("Supabase", source: "manual")
        _ = try? await store.addTerm("tokopedia", source: "history")
        let rule = try? await store.addReplacement(
            from: "super base", to: "Supabase", source: "manual")
        _ = try? await store.addReplacement(from: "teh", to: "the", source: "history")
        _ = try? await store.addReplacement(from: "hush", to: "Hush", source: "learned")
        if let rule { try? await store.bumpHitCounts([rule.id: 3]) }
        _ = try? await store.recordSuggestion(from: "supa base", to: "Supabase")
        _ = try? await store.recordSuggestion(from: "gak", to: "nggak")
    }

    /// A device list for snapshots: internal + AirPods connected, a USB mic
    /// that has since been unplugged (stays in the priority list, greyed).
    /// The mic store is in-memory in snapshot mode — nothing persists.
    private static func seedDevices(model: AppModel) {
        model.listInputDevices = {
            [InputDevice(uid: "builtin-mic", name: "MacBook Pro Microphone"),
             InputDevice(uid: "yeti-usb", name: "Yeti Stereo Microphone"),
             InputDevice(uid: "airpods-pro", name: "Zaky's AirPods Pro")]
        }
        model.refreshDevices()
        // Second refresh without the Yeti → known but DISCONNECTED.
        model.listInputDevices = {
            [InputDevice(uid: "builtin-mic", name: "MacBook Pro Microphone"),
             InputDevice(uid: "airpods-pro", name: "Zaky's AirPods Pro")]
        }
        model.refreshDevices()
    }

    /// The side panel on a mid-grey "wallpaper" so the inverted corners
    /// where the shape meets the screen edge are visible in the PNG. The
    /// fixed-size window (288×472) is offset so the silhouette's flush edge
    /// lands on the canvas edge, like a real screen edge.
    private static func renderEdge(model: AppModel, expanded: Bool,
                                   attachment: SidePanelAttachment = .right,
                                   reducedMotion: Bool = false,
                                   sliver: Bool = false,
                                   name: String, in dir: URL) {
        model.geometry.edgeExpanded = false   // verification may linger
        model.geometry.railCenterY = nil
        let win = EdgePanelLayout.window
        let view = ZStack(alignment: .center) {
            LinearGradient(
                colors: [Color(hb: 0x8E939B), Color(hb: 0x676C73)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            EdgePanelView(model: model, geometry: model.geometry,
                          forceExpanded: expanded, forceAttachment: attachment,
                          forceSliver: sliver)
                .frame(width: win.width, height: win.height)
                .offset(x: attachment == .right ? EdgePanelLayout.margin
                        : attachment == .left ? -EdgePanelLayout.margin : 0)
        }
        render(view.environment(\.hushReducedMotion, reducedMotion),
               size: CGSize(width: win.width, height: 560), name: name, in: dir)
    }

    /// Real window capture: builds the same window MainWindowController shows,
    /// orders it in, lets layout settle, then draws the contentView into a
    /// 2× bitmap. Captures NSView-backed controls (Form, TextField) that
    /// ImageRenderer cannot.
    private static func capturePage(_ page: MainPage, model: AppModel,
                                    expandedID: String? = nil, height: CGFloat = 680,
                                    name: String, in dir: URL) {
        let window = MainWindowController.makeWindow(
            model: model, page: page, expandedID: expandedID)
        // NSHostingView drags the window to the root view's ideal size during
        // layout — give the root an explicit fixed frame so the ideal size IS
        // the capture size (min/max clamps don't help: hosting views resize
        // via setFrame, which bypasses them).
        window.contentView = NSHostingView(rootView:
            MainWindowView(model: model, initialPage: page, initialExpandedID: expandedID)
                .frame(width: 1000, height: height))
        window.orderFrontRegardless()
        // Let SwiftUI layout + async fetches settle.
        for _ in 0..<15 { RunLoop.current.run(until: Date().addingTimeInterval(0.06)) }
        window.setContentSize(NSSize(width: 1000, height: height))
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.06)) }
        guard let view = window.contentView else {
            print("snapshot FAILED (no contentView): \(name)")
            window.close()
            return
        }
        let viewBounds = view.bounds
        let bounds: NSRect
        if abs(viewBounds.height - height) < 1 {
            bounds = viewBounds
        } else {
            // View kept an oversized ideal height — capture the top `height`.
            bounds = view.isFlipped
                ? NSRect(x: 0, y: 0, width: 1000, height: height)
                : NSRect(x: 0, y: viewBounds.height - height, width: 1000, height: height)
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("snapshot FAILED (no rep): \(name)")
            window.close()
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appending(path: "\(name).png"))
        } else {
            print("snapshot FAILED: \(name)")
        }
        window.close()
    }

    /// AppKit view → PNG at 2× (the Touch Bar wave is an NSView, not SwiftUI).
    private static func renderView(_ view: NSView, scale: CGFloat = 2,
                                   name: String, in dir: URL) {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("snapshot FAILED (no rep): \(name)")
            return
        }
        rep.size = NSSize(width: bounds.width * scale,
                          height: bounds.height * scale)
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appending(path: "\(name).png"))
        } else {
            print("snapshot FAILED: \(name)")
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize,
                                        name: String, in dir: URL) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("snapshot FAILED: \(name)")
            return
        }
        try? png.write(to: dir.appending(path: "\(name).png"))
    }
}
