import Testing
@testable import HushCore

@Test func placeholder() {
    let buffer = AudioBuffer16k(samples: [Float](repeating: 0, count: 16_000))
    #expect(buffer.duration == 1)
}
