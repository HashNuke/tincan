import AVFoundation
import Testing
@testable import tincan

struct AudioInputFormatResolverTests {
    @Test func tapFormatOverrideIsNilWhenFormatsAlreadyMatch() throws {
        let hardware = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )

        #expect(
            AudioInputFormatResolver.tapFormatOverride(
                hardwareInputFormat: hardware,
                outputFormat: hardware
            ) == nil
        )
    }

    @Test func tapFormatOverrideUsesHardwareFormatWhenNodeOutputDrifts() throws {
        let hardware = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let staleOutput = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let override = try #require(
            AudioInputFormatResolver.tapFormatOverride(
                hardwareInputFormat: hardware,
                outputFormat: staleOutput
            )
        )

        #expect(override.sampleRate == hardware.sampleRate)
        #expect(override.channelCount == hardware.channelCount)
        #expect(override.commonFormat == hardware.commonFormat)
        #expect(override.isInterleaved == hardware.isInterleaved)
    }
}
