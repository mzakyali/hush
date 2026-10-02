import AVFoundation
import Foundation
import HushCore

/// Writes recorded audio to `.m4a` (AAC, 16 kHz mono, ~32 kbps) for history playback.
public enum AudioEncoder {
    public static func writeM4A(_ buffer: AudioBuffer16k, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.converterFailed
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount = AVAudioFrameCount(buffer.samples.count)
        guard frameCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        pcm.frameLength = frameCount
        buffer.samples.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memcpy(pcm.floatChannelData![0], base, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }
        try file.write(from: pcm)
    }
}
