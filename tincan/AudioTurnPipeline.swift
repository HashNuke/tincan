#if os(iOS) || os(macOS)
import AVFoundation
import CoreML
import FluidAudio
import Foundation

@MainActor
protocol AudioTurnPipelineOutput: AnyObject {
    func audioTurnPipelineDidLog(_ message: String)
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
            do {
                let resampled = try self.tapAudioConverter.resampleBuffer(buffer)
                self.audioStreamContinuation?.yield(resampled)
            } catch {
                Task {
                    await self.sink.emitLog("Failed to resample input buffer: \(error.localizedDescription)")
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        await sink.emitLog("Microphone capture started")
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
        await sink.emitLog("Microphone capture stopped")
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

    func setDelegate(_ delegate: (any AudioTurnPipelineOutput)?) {
        self.delegate = delegate
    }

    func emitLog(_ message: String) async {
        await delegate?.audioTurnPipelineDidLog(message)
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
