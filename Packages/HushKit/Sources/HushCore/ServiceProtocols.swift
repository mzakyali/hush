import ApplicationServices
import Foundation

public struct RecordedAudio: Sendable {
    public var buffer: AudioBuffer16k
    public var duration: TimeInterval

    public init(buffer: AudioBuffer16k, duration: TimeInterval) {
        self.buffer = buffer
        self.duration = duration
    }
}

/// Implemented by `AudioCapture.AudioRecorder`.
public protocol AudioRecording: Sendable {
    /// Fresh 0…1 level stream for one recording. AsyncStream is single-consumer
    /// and a cancelled iteration terminates it, so each recording needs a new
    /// stream; making one finishes the previous stream's continuation.
    nonisolated func makeLevelStream() -> AsyncStream<Float>
    /// Fresh 16 kHz mono chunk stream (for streaming ASR partials). Unused while
    /// partials are off — don't create one unless something consumes it.
    nonisolated func makeChunkStream() -> AsyncStream<AudioBuffer16k>
    /// Name of the input device actually in use (shown by the overlay).
    var activeDeviceName: String? { get }
    func start(deviceUID: String?) async throws
    func stop() async throws -> RecordedAudio
    func cancel() async
}

/// Sendable box for an AXUIElement (a CoreFoundation type — moving the reference is safe).
public struct InsertedElement: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

/// What the AX query found about the focused element.
public struct FocusedElementInfo: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    /// Element is a secure text field (e.g. AXSecureTextField subrole).
    public var isSecure: Bool
    /// AXValue or AXSelectedTextRange is settable on the element.
    public var acceptsTextInput: Bool

    public init(role: String? = nil, subrole: String? = nil, isSecure: Bool = false,
                acceptsTextInput: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.isSecure = isSecure
        self.acceptsTextInput = acceptsTextInput
    }
}

/// The insertion target captured when recording stops — the spec target is the app
/// focused at stop time, not at insert time (~4 s later).
public struct InsertionTarget: Sendable {
    public var bundleID: String?
    public var pid: pid_t?
    public var elementInfo: FocusedElementInfo?
    public var element: InsertedElement?

    public init(bundleID: String? = nil, pid: pid_t? = nil,
                elementInfo: FocusedElementInfo? = nil, element: InsertedElement? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.elementInfo = elementInfo
        self.element = element
    }
}

public enum InsertionResult: Sendable {
    /// `insertedLength` is the UTF-16 length of what actually landed in the
    /// target — including any smart leading space — so a paste-raw replace of
    /// the last insertion selects the right range.
    case pasted(appBundleID: String?, element: InsertedElement?, insertedLength: Int)
    case copiedToClipboard
}

/// Implemented by `Insertion.Inserter`.
public protocol Inserting: Sendable {
    /// Snapshot the frontmost app's pid, bundle id and focused element.
    func captureTarget() async -> InsertionTarget
    /// Paste into `target`, or leave the text on the clipboard if the user switched
    /// apps since capture or no safe target exists.
    func insert(_ text: String, target: InsertionTarget) async throws -> InsertionResult
    /// ⌃⌥Z paste-raw (spec §3.9/T11): replace the last pasted insertion with
    /// `raw` when the target still contains exactly what was inserted.
    /// `raw`/`cleaned` are the last dictation's texts (nil = none yet).
    /// Failure paths notify the user; never throws.
    func replaceLastInsertion(raw: String?, cleaned: String?) async
}
