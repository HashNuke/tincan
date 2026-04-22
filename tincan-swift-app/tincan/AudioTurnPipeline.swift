#if os(iOS) || os(macOS)
import AVFoundation
import CoreML
import FluidAudio
import Foundation

@MainActor
protocol AudioTurnPipelineOutput: AnyObject {
    func audioTurnPipelineDidLog(_ message: String)
    func audioTurnPipelineDidUpdateInputLevel(_ level: Float)
    func audioTurnPipelineDidCaptureSegment(_ segment: CapturedSpeechSegment)
}

final class AudioTurnPipeline {
    private var audioEngine = AVAudioEngine()
    private let tapAudioConverter = AudioConverter()
    private let sink = TurnEventSink()
    private let turnDetector: VadTurnDetector

    private var audioStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var isRunning = false
    private var tapInputDeviceName = "Unknown input device"
    private var tapCallbackCount = 0
    private var tapDebugLogCount = 0
    private var tapRejectedDebugLogCount = 0
    private var didLogInputSignal = false
    private var didWarnAboutSilentInput = false
    private var didLogFallbackResampler = false

    init() {
        turnDetector = VadTurnDetector(sink: sink)
    }

    func setDelegate(_ delegate: (any AudioTurnPipelineOutput)?) {
        Task {
            await sink.setDelegate(delegate)
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        try await turnDetector.prepare()
        audioEngine = AVAudioEngine()
        tapInputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Unknown input device"
        tapCallbackCount = 0
        tapDebugLogCount = 0
        tapRejectedDebugLogCount = 0
        didLogInputSignal = false
        didWarnAboutSilentInput = false
        didLogFallbackResampler = false

        let stream = AsyncStream<[Float]> { continuation in
            audioStreamContinuation = continuation
        }

        processingTask = Task { [turnDetector, sink] in
            for await samples in stream {
                do {
                    try await turnDetector.append(samples: samples)
                } catch {
                    await sink.emitLog("VAD pipeline failed: \(error.localizedDescription)")
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw AudioTurnPipelineError.noInputChannels
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleTapBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        await sink.resetInputLevel()
        await sink.emitLog("Using microphone: \(tapInputDeviceName)")
        await sink.emitLog("Microphone tap format: \(AudioTapSamples.describe(bufferFormat: inputFormat))")
        await sink.emitLog("Microphone capture started")

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isRunning, self.tapCallbackCount == 0 else { return }
            await self.sink.emitLog(
                "Microphone tap started but has not delivered any buffers after 2s. Tap format: \(AudioTapSamples.describe(bufferFormat: inputFormat))"
            )
        }
    }

    func stop() async {
        guard isRunning else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        processingTask?.cancel()
        processingTask = nil
        isRunning = false
        audioEngine = AVAudioEngine()
        await turnDetector.reset()
        await sink.resetInputLevel()
        await sink.emitLog("Microphone capture stopped")
    }

    private static func normalizedInputLevel(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let meanSquare = samples.reduce(into: Float.zero) { partialResult, sample in
            partialResult += sample * sample
        } / Float(samples.count)

        let rms = sqrt(meanSquare)
        let floorLevel: Float = -48
        let decibels = 20 * log10(max(rms, 0.000_01))
        let normalized = max(0, min(1, (decibels - floorLevel) / -floorLevel))

        // Ease the meter slightly so conversational speech is visible.
        return Float(pow(Double(normalized), 0.65))
    }

    private func handleTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard AudioTapBufferValidator.shouldProcess(buffer) else {
            if tapRejectedDebugLogCount < 3 {
                tapRejectedDebugLogCount += 1
                let rejectionReason = AudioTapBufferValidator.rejectionReason(for: buffer) ?? "unknown reason"
                let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let bufferSizes = audioBuffers.map(\.mDataByteSize)
                Task {
                    await self.sink.emitLog(
                        "Rejected microphone tap buffer (\(rejectionReason)); frameLength=\(buffer.frameLength), buffers=\(audioBuffers.count), sizes=\(bufferSizes)"
                    )
                }
            }
            return
        }

        tapCallbackCount += 1
        if tapDebugLogCount < 3 {
            tapDebugLogCount += 1
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bufferSizes = audioBuffers.map(\.mDataByteSize)
            Task {
                await self.sink.emitLog(
                    "Received microphone tap buffer #\(self.tapCallbackCount); frameLength=\(buffer.frameLength), format=\(AudioTapSamples.describe(bufferFormat: buffer.format)), sizes=\(bufferSizes)"
                )
            }
        }

        let rawSamples = AudioTapSamples.extractMonoFloatSamples(from: buffer)
        let inputLevel = Self.normalizedInputLevel(from: rawSamples)

        Task {
            await self.sink.emitInputLevel(inputLevel)
        }

        if inputLevel >= 0.03, !didLogInputSignal {
            didLogInputSignal = true
            Task {
                await self.sink.emitLog("Microphone input signal detected")
            }
        } else if tapCallbackCount >= 45, !didLogInputSignal, !didWarnAboutSilentInput {
            didWarnAboutSilentInput = true
            Task {
                await self.sink.emitLog(
                    "Microphone tap is active but the signal is near silent. Current input device: \(self.tapInputDeviceName)"
                )
            }
        }

        do {
            let resampled = try resampledTapSamples(from: buffer, rawSamples: rawSamples)
            guard !resampled.isEmpty else {
                return
            }
            audioStreamContinuation?.yield(resampled)
        } catch {
            Task {
                await self.sink.emitLog("Failed to prepare input buffer for VAD: \(error.localizedDescription)")
            }
        }
    }

    private func resampledTapSamples(from buffer: AVAudioPCMBuffer, rawSamples: [Float]) throws -> [Float] {
        do {
            let converted = try tapAudioConverter.resampleBuffer(buffer)
            if !converted.isEmpty {
                return converted
            }
        } catch {
            if !didLogFallbackResampler {
                didLogFallbackResampler = true
                Task {
                    await self.sink.emitLog(
                        "Primary microphone converter failed for format \(AudioTapSamples.describe(bufferFormat: buffer.format)): \(error.localizedDescription)"
                    )
                }
            }
        }

        return try fallbackResampledTapSamples(from: buffer, rawSamples: rawSamples)
    }

    private func fallbackResampledTapSamples(from buffer: AVAudioPCMBuffer, rawSamples: [Float]) throws -> [Float] {
        if !didLogFallbackResampler {
            didLogFallbackResampler = true
            Task {
                await self.sink.emitLog(
                    "Falling back to manual microphone conversion for format \(AudioTapSamples.describe(bufferFormat: buffer.format))"
                )
            }
        }

        return AudioTapSamples.resample(
            rawSamples,
            from: buffer.format.sampleRate,
            to: Double(VadManager.sampleRate)
        )
    }
}

enum AudioTapBufferValidator {
    static func shouldProcess(_ buffer: AVAudioPCMBuffer) -> Bool {
        rejectionReason(for: buffer) == nil
    }

    static func rejectionReason(for buffer: AVAudioPCMBuffer) -> String? {
        guard buffer.frameLength > 0 else {
            return "frameLength is zero"
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard !audioBuffers.isEmpty else {
            return "audio buffer list is empty"
        }

        for (index, audioBuffer) in audioBuffers.enumerated() {
            if audioBuffer.mData == nil {
                return "buffer \(index) has nil mData"
            }
            if audioBuffer.mDataByteSize == 0 {
                return "buffer \(index) has zero byte size"
            }
        }

        return nil
    }
}

enum AudioTapSamples {
    static func extractMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        guard frameCount > 0, channelCount > 0 else {
            return []
        }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            return extractFloat32Samples(from: buffer, frameCount: frameCount, channelCount: channelCount)
        case .pcmFormatInt16:
            return extractInt16Samples(from: buffer, frameCount: frameCount, channelCount: channelCount)
        case .pcmFormatInt32:
            return extractInt32Samples(from: buffer, frameCount: frameCount, channelCount: channelCount)
        case .pcmFormatFloat64:
            return extractFloat64Samples(from: buffer, frameCount: frameCount, channelCount: channelCount)
        default:
            return []
        }
    }

    static func resample(_ samples: [Float], from inputSampleRate: Double, to outputSampleRate: Double) -> [Float] {
        guard !samples.isEmpty, inputSampleRate > 0, outputSampleRate > 0 else {
            return []
        }

        if abs(inputSampleRate - outputSampleRate) < 0.5 {
            return samples
        }

        let ratio = inputSampleRate / outputSampleRate
        let outputCount = max(1, Int((Double(samples.count) / ratio).rounded(.toNearestOrEven)))
        var output = [Float](repeating: 0, count: outputCount)

        for index in 0..<outputCount {
            let sourceIndex = Double(index) * ratio
            let lowerIndex = min(samples.count - 1, Int(sourceIndex.rounded(.down)))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            output[index] = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
        }

        return output
    }

    static func describe(bufferFormat format: AVAudioFormat) -> String {
        let formatName: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            formatName = "Float32"
        case .pcmFormatFloat64:
            formatName = "Float64"
        case .pcmFormatInt16:
            formatName = "Int16"
        case .pcmFormatInt32:
            formatName = "Int32"
        case .otherFormat:
            formatName = "Other"
        @unknown default:
            formatName = "Unknown"
        }

        let layout = format.isInterleaved ? "interleaved" : "non-interleaved"
        return "\(Int(format.channelCount)) ch @ \(Int(format.sampleRate)) Hz \(formatName) \(layout)"
    }

    private static func extractFloat32Samples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if buffer.format.isInterleaved {
            guard let audioBuffer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first,
                  let data = audioBuffer.mData else {
                return []
            }

            let samples = data.assumingMemoryBound(to: Float.self)
            return mixInterleaved(samples: samples, frameCount: frameCount, channelCount: channelCount)
        }

        guard let channelData = buffer.floatChannelData else {
            return []
        }

        return mixNonInterleaved(
            frameCount: frameCount,
            channelCount: channelCount
        ) { channel, frame in
            channelData[channel][frame]
        }
    }

    private static func extractInt16Samples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if buffer.format.isInterleaved {
            guard let audioBuffer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first,
                  let data = audioBuffer.mData else {
                return []
            }

            let samples = data.assumingMemoryBound(to: Int16.self)
            return mixInterleaved(samples: samples, frameCount: frameCount, channelCount: channelCount) {
                Float($0) / Float(Int16.max)
            }
        }

        guard let channelData = buffer.int16ChannelData else {
            return []
        }

        return mixNonInterleaved(
            frameCount: frameCount,
            channelCount: channelCount
        ) { channel, frame in
            Float(channelData[channel][frame]) / Float(Int16.max)
        }
    }

    private static func extractInt32Samples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if buffer.format.isInterleaved {
            guard let audioBuffer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first,
                  let data = audioBuffer.mData else {
                return []
            }

            let samples = data.assumingMemoryBound(to: Int32.self)
            return mixInterleaved(samples: samples, frameCount: frameCount, channelCount: channelCount) {
                Float($0) / Float(Int32.max)
            }
        }

        guard let channelData = buffer.int32ChannelData else {
            return []
        }

        return mixNonInterleaved(
            frameCount: frameCount,
            channelCount: channelCount
        ) { channel, frame in
            Float(channelData[channel][frame]) / Float(Int32.max)
        }
    }

    private static func extractFloat64Samples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        if buffer.format.isInterleaved {
            guard let audioBuffer = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first,
                  let data = audioBuffer.mData else {
                return []
            }

            let samples = data.assumingMemoryBound(to: Double.self)
            return mixInterleaved(samples: samples, frameCount: frameCount, channelCount: channelCount) {
                Float($0)
            }
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard audioBuffers.count >= channelCount else {
            return []
        }

        return mixNonInterleaved(
            frameCount: frameCount,
            channelCount: channelCount
        ) { channel, frame in
            guard let data = audioBuffers[channel].mData else {
                return 0
            }
            let samples = data.assumingMemoryBound(to: Double.self)
            return Float(samples[frame])
        }
    }

    private static func mixNonInterleaved(
        frameCount: Int,
        channelCount: Int,
        sampleAt: (_ channel: Int, _ frame: Int) -> Float
    ) -> [Float] {
        var mono = [Float](repeating: 0, count: frameCount)
        let channelScale = 1 / Float(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sampleAt(channel, frame)
            }
            mono[frame] = sum * channelScale
        }

        return mono
    }

    private static func mixInterleaved<T>(
        samples: UnsafePointer<T>,
        frameCount: Int,
        channelCount: Int,
        convert: (T) -> Float
    ) -> [Float] {
        var mono = [Float](repeating: 0, count: frameCount)
        let channelScale = 1 / Float(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            let frameBaseIndex = frame * channelCount
            for channel in 0..<channelCount {
                sum += convert(samples[frameBaseIndex + channel])
            }
            mono[frame] = sum * channelScale
        }

        return mono
    }

    private static func mixInterleaved<T>(
        samples: UnsafePointer<T>,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] where T == Float {
        mixInterleaved(samples: samples, frameCount: frameCount, channelCount: channelCount, convert: { $0 })
    }
}

private enum AudioTurnPipelineError: LocalizedError {
    case noInputChannels

    var errorDescription: String? {
        switch self {
        case .noInputChannels:
            "No microphone input channels are available."
        }
    }
}

private actor TurnEventSink {
    weak var delegate: (any AudioTurnPipelineOutput)?
    private var lastInputLevelEmission = Date.distantPast
    private let minimumInputLevelEmissionInterval: TimeInterval = 1.0 / 15.0

    func setDelegate(_ delegate: (any AudioTurnPipelineOutput)?) {
        self.delegate = delegate
    }

    func emitLog(_ message: String) async {
        await delegate?.audioTurnPipelineDidLog(message)
    }

    func emitInputLevel(_ level: Float) async {
        let now = Date()
        guard now.timeIntervalSince(lastInputLevelEmission) >= minimumInputLevelEmissionInterval else {
            return
        }

        lastInputLevelEmission = now
        await delegate?.audioTurnPipelineDidUpdateInputLevel(level)
    }

    func resetInputLevel() async {
        lastInputLevelEmission = Date.distantPast
        await delegate?.audioTurnPipelineDidUpdateInputLevel(0)
    }

    func emitSegment(_ segment: CapturedSpeechSegment) async {
        await delegate?.audioTurnPipelineDidCaptureSegment(segment)
    }
}

private actor VadTurnDetector {
    private let sink: TurnEventSink

    private var vadManager: VadManager?
    private var streamState = VadStreamState.initial()
    private var pendingSamples: [Float] = []
    private var bufferedSamples: [Float] = []
    private var bufferBaseSampleIndex = 0
    private var currentSpeechStartSample: Int?

    private let maxBufferedSilenceSamples = VadManager.sampleRate * 2
    private let minSegmentDuration: TimeInterval = 0.35
    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.25,
        minSilenceDuration: 0.8,
        maxSpeechDuration: 12.0,
        speechPadding: 0.15
    )

    init(sink: TurnEventSink) {
        self.sink = sink
    }

    func prepare() async throws {
        if vadManager == nil {
            let config = VadConfig(
                defaultThreshold: 0.75,
                debugMode: false,
                computeUnits: currentComputeUnits
            )
            vadManager = try await VadManager(config: config)
            await sink.emitLog("FluidAudio VAD is ready")
        }

        await reset()
    }

    func reset() async {
        streamState = VadStreamState.initial()
        pendingSamples.removeAll(keepingCapacity: true)
        bufferedSamples.removeAll(keepingCapacity: true)
        bufferBaseSampleIndex = 0
        currentSpeechStartSample = nil
    }

    func append(samples: [Float]) async throws {
        guard !samples.isEmpty, let vadManager else { return }

        bufferedSamples.append(contentsOf: samples)
        pendingSamples.append(contentsOf: samples)
        pruneLeadingSilenceIfNeeded()

        while pendingSamples.count >= VadManager.chunkSize {
            let chunk = Array(pendingSamples.prefix(VadManager.chunkSize))
            pendingSamples.removeFirst(VadManager.chunkSize)

            let result = try await vadManager.processStreamingChunk(
                chunk,
                state: streamState,
                config: segmentationConfig
            )
            streamState = result.state

            guard let event = result.event else { continue }
            if event.isStart {
                currentSpeechStartSample = event.sampleIndex
                await sink.emitLog("Speech detected")
            } else if event.isEnd {
                try await finalizeSegment(endSample: event.sampleIndex)
            }
        }
    }

    private func finalizeSegment(endSample: Int) async throws {
        guard let currentSpeechStartSample else { return }

        let localStart = max(0, currentSpeechStartSample - bufferBaseSampleIndex)
        let localEnd = min(bufferedSamples.count, endSample - bufferBaseSampleIndex)

        guard localEnd > localStart else {
            self.currentSpeechStartSample = nil
            return
        }

        let turnSamples = Array(bufferedSamples[localStart..<localEnd])
        let duration = Double(turnSamples.count) / Double(VadManager.sampleRate)
        self.currentSpeechStartSample = nil

        pruneProcessedAudio(localEnd)

        guard duration >= minSegmentDuration else {
            await sink.emitLog("Ignored a short segment (\(duration.formatted(.number.precision(.fractionLength(2))))s)")
            return
        }

        let wavData = try AudioWAV.data(from: turnSamples, sampleRate: Double(VadManager.sampleRate))
        let segment = CapturedSpeechSegment(
            samples: turnSamples,
            wavData: wavData,
            sampleRate: VadManager.sampleRate,
            duration: duration
        )
        await sink.emitLog(
            "Prepared \(duration.formatted(.number.precision(.fractionLength(2))))s speech segment for classification"
        )
        await sink.emitSegment(segment)
    }

    private func pruneProcessedAudio(_ localEnd: Int) {
        guard localEnd > 0 else { return }
        bufferedSamples.removeFirst(localEnd)
        bufferBaseSampleIndex += localEnd
    }

    private func pruneLeadingSilenceIfNeeded() {
        guard currentSpeechStartSample == nil, bufferedSamples.count > maxBufferedSilenceSamples else { return }
        let dropCount = bufferedSamples.count - maxBufferedSilenceSamples
        bufferedSamples.removeFirst(dropCount)
        bufferBaseSampleIndex += dropCount
    }

    private var currentComputeUnits: MLComputeUnits {
#if targetEnvironment(simulator)
        .cpuOnly
#else
        .cpuAndNeuralEngine
#endif
    }
}
#endif
