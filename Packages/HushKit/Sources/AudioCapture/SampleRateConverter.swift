import AVFoundation

/// Resamples any input PCM format to 16 kHz mono Float32 via `AVAudioConverter`.
/// Callers must serialize `convert(_:)` on a given instance (the recorder's tap is serial).
public final class SampleRateConverter: @unchecked Sendable {
    public static let outputSampleRate: Double = 16_000

    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public enum Error: Swift.Error {
        case unsupportedFormat
        case conversionFailed(String)
    }

    public init(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Error.unsupportedFormat
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    public convenience init(inputSampleRate: Double, channels: AVAudioChannelCount = 1) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw Error.unsupportedFormat
        }
        try self.init(inputFormat: format)
    }

    /// Convert an input buffer to a 16 kHz mono Float32 buffer.
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = Self.outputSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Error.conversionFailed("could not allocate output buffer")
        }
        var conversionError: NSError?
        var consumed = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                // .noDataNow, not .endOfStream — the converter is shared across
                // convert() calls and EOS permanently ends its input stream.
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            throw Error.conversionFailed(conversionError.localizedDescription)
        }
        return output
    }

    /// Convert an interleaved-or-mono Float32 sample array at `inputRate` to 16 kHz mono.
    public func convertSamples(_ samples: [Float], inputRate: Double, channels: Int = 1) throws -> [Float] {
        let converter = try SampleRateConverter(
            inputSampleRate: inputRate,
            channels: AVAudioChannelCount(channels)
        )
        let frameCount = AVAudioFrameCount(samples.count / channels)
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frameCount) else {
            throw Error.conversionFailed("could not allocate input buffer")
        }
        input.frameLength = frameCount
        let dest = input.floatChannelData!
        if channels == 1 {
            _ = samples.withUnsafeBytes { src in
                memcpy(dest[0], src.baseAddress, Int(frameCount) * MemoryLayout<Float>.size)
            }
        } else {
            // De-interleave into per-channel planes.
            for ch in 0 ..< channels {
                for i in 0 ..< Int(frameCount) {
                    dest[ch][i] = samples[i * channels + ch]
                }
            }
        }
        let output = try converter.convert(input)
        let n = Int(output.frameLength)
        guard n > 0, let channelData = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: n))
    }
}
