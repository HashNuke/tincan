import AVFoundation
import Foundation

@MainActor
final class CallTonePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = CallTonePlayer()

    private var activePlayers: [AVAudioPlayer] = []

    func playConnectTone() {
        playTone(sequence: [
            ToneSegment(frequency: 880, duration: 0.08),
            ToneSegment(frequency: 1320, duration: 0.12),
        ])
    }

    func playDisconnectTone() {
        playTone(sequence: [
            ToneSegment(frequency: 880, duration: 0.08),
            ToneSegment(frequency: 660, duration: 0.1),
            ToneSegment(frequency: 440, duration: 0.12),
        ])
    }

    private func playTone(sequence: [ToneSegment]) {
        do {
            let audioData = try ToneWaveform.render(sequence: sequence)
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            activePlayers.append(player)
            player.play()
        } catch {
            assertionFailure("Failed to play call tone: \(error.localizedDescription)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        activePlayers.removeAll { $0 === player }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        activePlayers.removeAll { $0 === player }
    }
}

private struct ToneSegment {
    let frequency: Double
    let duration: TimeInterval
}

private enum ToneWaveform {
    static func render(sequence: [ToneSegment], sampleRate: Int = 44_100) throws -> Data {
        let sampleRateDouble = Double(sampleRate)
        var pcm = Data()

        for segment in sequence {
            let frameCount = Int(segment.duration * sampleRateDouble)
            guard frameCount > 0 else { continue }

            for frame in 0..<frameCount {
                let t = Double(frame) / sampleRateDouble
                let ramp = min(1.0, Double(frame) / max(1.0, Double(frameCount) * 0.15))
                let releaseFrames = max(1.0, Double(frameCount) * 0.2)
                let releaseStart = Double(frameCount) - releaseFrames
                let release = frame >= Int(releaseStart)
                    ? max(0.0, (Double(frameCount) - Double(frame)) / releaseFrames)
                    : 1.0
                let envelope = ramp * release
                let sample = sin(2.0 * .pi * segment.frequency * t) * 0.22 * envelope
                var intSample = Int16(max(-1.0, min(1.0, sample)) * Double(Int16.max))
                pcm.append(Data(bytes: &intSample, count: MemoryLayout<Int16>.size))
            }
        }

        return wavData(forPCM: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
    }

    private static func wavData(forPCM pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let riffChunkSize = 36 + pcm.count

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndian(UInt32(riffChunkSize)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(UInt16(channels)))
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(byteRate)))
        data.append(littleEndian(UInt16(blockAlign)))
        data.append(littleEndian(UInt16(bitsPerSample)))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndian(UInt32(pcm.count)))
        data.append(pcm)
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
