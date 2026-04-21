import AVFoundation
import Testing
@testable import tincan

struct AudioTapBufferValidatorTests {
    @Test func rejectsBufferWithZeroFrameLength() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 0

        #expect(!AudioTapBufferValidator.shouldProcess(buffer))
    }

    @Test func acceptsPopulatedBuffer() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 128
        let channelData = try #require(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            channelData[0][index] = Float(index)
        }

        #expect(AudioTapBufferValidator.shouldProcess(buffer))
    }
}
