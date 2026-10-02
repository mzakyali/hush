import CoreAudio
import Foundation

/// Fires on the main run loop when CoreAudio's device list changes
/// (`kAudioHardwarePropertyDevices` on the system object) — spec §4a: Hush
/// re-selects on connect/disconnect, applied to the next recording only.
public final class DeviceListMonitor: @unchecked Sendable {
    private var block: AudioObjectPropertyListenerBlock?
    private var installed = false

    public init(onChange: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        installed = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        ) == noErr
        self.block = installed ? block : nil
    }

    deinit {
        guard installed, let block else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}
