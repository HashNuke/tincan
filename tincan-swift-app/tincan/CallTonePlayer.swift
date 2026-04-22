import AVFoundation
import Foundation

@MainActor
final class CallTonePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = CallTonePlayer()
    private static let minimumOutgoingRingDuration: TimeInterval = 1.5

    private var activePlayers: [AVAudioPlayer] = []
    private var outgoingRingPlayer: AVAudioPlayer?
    private var outgoingRingStartedAt: Date?
    private var outgoingRingToken = UUID()

    var isPlayingAudio: Bool {
        outgoingRingPlayer?.isPlaying == true || !activePlayers.isEmpty
    }

    func playConnectTone() {
        stopOutgoingRing()
        playTone(sequence: [
            ToneSegment(frequency: 880, duration: 0.08),
            ToneSegment(frequency: 1320, duration: 0.12),
        ])
    }

    func playDisconnectTone() {
        stopOutgoingRing()
        if let url = bundledAudioAssetURL(named: "call_disconnect") {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                player.prepareToPlay()
                activePlayers.append(player)
                player.play()
                return
            } catch {
                assertionFailure("Failed to play disconnect audio asset: \(error.localizedDescription)")
            }
        }
        playTone(sequence: [
            ToneSegment(frequency: 880, duration: 0.08),
            ToneSegment(frequency: 660, duration: 0.1),
            ToneSegment(frequency: 440, duration: 0.12),
        ])
    }

    func startOutgoingRing() {
        guard outgoingRingPlayer?.isPlaying != true else { return }
        guard let url = outgoingRingURL() else {
            assertionFailure("Failed to locate outgoing ring audio asset")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.numberOfLoops = -1
            player.prepareToPlay()
            outgoingRingPlayer = player
            outgoingRingStartedAt = Date()
            outgoingRingToken = UUID()
            player.play()
        } catch {
            assertionFailure("Failed to play outgoing ring audio asset: \(error.localizedDescription)")
        }
    }

    func playConnectToneWhenOutgoingRingMinimumElapsed() async {
        let ringToken = outgoingRingToken
        if let outgoingRingStartedAt {
            let elapsed = Date().timeIntervalSince(outgoingRingStartedAt)
            let remaining = Self.minimumOutgoingRingDuration - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        guard outgoingRingToken == ringToken, outgoingRingPlayer?.isPlaying == true else { return }
        playConnectTone()
    }

    func stopOutgoingRing() {
        outgoingRingPlayer?.stop()
        outgoingRingPlayer = nil
        outgoingRingStartedAt = nil
        outgoingRingToken = UUID()
    }

    func playAudioData(_ audioData: Data) {
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            activePlayers.append(player)
            player.play()
        } catch {
            assertionFailure("Failed to play audio data: \(error.localizedDescription)")
        }
    }

    private func playTone(sequence: [ToneSegment]) {
        do {
            let audioData = try ToneWaveform.render(sequence: sequence)
            playAudioData(audioData)
        } catch {
            assertionFailure("Failed to play call tone: \(error.localizedDescription)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if outgoingRingPlayer === player {
            outgoingRingPlayer = nil
            return
        }
        activePlayers.removeAll { $0 === player }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        if outgoingRingPlayer === player {
            outgoingRingPlayer = nil
            return
        }
        activePlayers.removeAll { $0 === player }
    }

    private func outgoingRingURL() -> URL? {
        bundledAudioAssetURL(named: "phone-ring-out-call-end-tone")
    }

    private func bundledAudioAssetURL(named resourceName: String) -> URL? {
        if let bundledURL = Bundle.main.url(forResource: resourceName, withExtension: "wav") {
            return bundledURL
        }

        if let frameworkURL = Bundle(for: CallTonePlayer.self).url(forResource: resourceName, withExtension: "wav") {
            return frameworkURL
        }

        let sourceAssetURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAssets", isDirectory: true)
            .appendingPathComponent("\(resourceName).wav", isDirectory: false)
        guard FileManager.default.fileExists(atPath: sourceAssetURL.path) else {
            return nil
        }
        return sourceAssetURL
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
