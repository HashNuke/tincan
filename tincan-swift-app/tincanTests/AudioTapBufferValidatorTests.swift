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

    @Test func extractsMonoSamplesFromStereoFloatBuffer() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        let channelData = try #require(buffer.floatChannelData)
        let left: [Float] = [0, 1, 0.5, -0.5]
        let right: [Float] = [1, 0, -0.5, 0.5]

        for index in 0..<Int(buffer.frameLength) {
            channelData[0][index] = left[index]
            channelData[1][index] = right[index]
        }

        let mono = AudioTapSamples.extractMonoFloatSamples(from: buffer)
        #expect(mono.count == 4)
        #expect(abs(mono[0] - 0.5) < 0.0001)
        #expect(abs(mono[1] - 0.5) < 0.0001)
        #expect(abs(mono[2]) < 0.0001)
        #expect(abs(mono[3]) < 0.0001)
    }

    @Test func extractsMonoSamplesFromInterleavedInt16Buffer() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3

        let audioBuffer = try #require(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first)
        let samples = try #require(audioBuffer.mData?.assumingMemoryBound(to: Int16.self))
        samples[0] = 0
        samples[1] = Int16.max
        samples[2] = Int16.max
        samples[3] = Int16.max
        samples[4] = -Int16.max
        samples[5] = Int16.max

        let mono = AudioTapSamples.extractMonoFloatSamples(from: buffer)
        #expect(mono.count == 3)
        #expect(abs(mono[0] - 0.5) < 0.001)
        #expect(abs(mono[1] - 1.0) < 0.001)
        #expect(abs(mono[2]) < 0.001)
    }

    @Test func resamplesMonoSamplesToTargetRate() {
        let resampled = AudioTapSamples.resample([0, 1, 2, 3, 4, 5], from: 6, to: 3)

        #expect(resampled.count == 3)
        #expect(abs(resampled[0] - 0) < 0.0001)
        #expect(abs(resampled[1] - 2) < 0.0001)
        #expect(abs(resampled[2] - 4) < 0.0001)
    }
}
