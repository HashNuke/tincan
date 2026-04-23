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
    private let captureState = AudioTurnPipelineCaptureState()
    private let tapState = AudioTurnPipelineTapState()

    private var audioStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var engineRecoveryTask: Task<Void, Never>?
    private var isRunning = false
    private var isRecoveringEngine = false
    
    private var tapTimeoutRecoveryAttempts = 0
    private let maximumTapTimeoutRecoveryAttempts = 1
    private let maximumDigitalSilenceRecoveryAttempts = 1
    private let minimumDigitalSilenceRecoveryDuration: TimeInterval = 3
    private let digitalSilencePeakThreshold: Float = 0.000_001
    private let engineRecoveryRestartDelayNanoseconds: UInt64 = 750_000_000
    private var engineConfigurationObserver: NSObjectProtocol?
#if os(macOS)
    private var captureDeviceConnectedObserver: NSObjectProtocol?
    private var captureDeviceDisconnectedObserver: NSObjectProtocol?
#endif

    init() {
        turnDetector = VadTurnDetector(sink: sink)
    }

    deinit {
        engineRecoveryTask?.cancel()
        removeObservers()
    }

    func setDelegate(_ delegate: (any AudioTurnPipelineOutput)?) {
        Task {
            await sink.setDelegate(delegate)
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        try await turnDetector.prepare()
        captureState.setEnabled(true)
        tapTimeoutRecoveryAttempts = 0
        tapState.resetDigitalSilenceRecovery()

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

        isRunning = true
        installObservers()
        do {
            try await startAudioEngine(recoveryReason: nil)
        } catch {
            removeObservers()
            stopAudioEngine()
            audioStreamContinuation?.finish()
            audioStreamContinuation = nil
            processingTask?.cancel()
            processingTask = nil
            isRunning = false
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }

        isRunning = false
        engineRecoveryTask?.cancel()
        engineRecoveryTask = nil
        isRecoveringEngine = false
        removeObservers()
        stopAudioEngine()
        tapTimeoutRecoveryAttempts = 0
        tapState.resetDigitalSilenceRecovery()
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        processingTask?.cancel()
        processingTask = nil
        isRunning = false
        audioEngine = AVAudioEngine()
        captureState.setEnabled(true)
        await turnDetector.reset()
        await sink.resetInputLevel()
        await sink.emitLog("Microphone capture stopped")
    }

    func setCaptureEnabled(_ enabled: Bool) async {
        captureState.setEnabled(enabled)
        await turnDetector.reset()
        await sink.resetInputLevel()
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
            if tapState.registerRejectedTap() {
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

        let tapInfo = tapState.registerTapCallback()
        if tapInfo.count == 1 {
            tapTimeoutRecoveryAttempts = 0
        }
        if tapInfo.shouldLogDebug {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bufferSizes = audioBuffers.map(\.mDataByteSize)
            Task {
                await self.sink.emitLog(
                    "Received microphone tap buffer #\(tapInfo.count); frameLength=\(buffer.frameLength), format=\(AudioTapSamples.describe(bufferFormat: buffer.format)), sizes=\(bufferSizes)"
                )
            }
        }

        guard captureState.isEnabled else {
            return
        }

        let rawSamples = AudioTapSamples.extractMonoFloatSamples(from: buffer)
        let inputLevel = Self.normalizedInputLevel(from: rawSamples)
        updateDigitalSilenceDiagnostics(rawSamples: rawSamples, buffer: buffer)

        Task {
            await self.sink.emitInputLevel(inputLevel)
        }

        if inputLevel >= 0.03, !tapState.markDidLogInputSignal() {
            Task {
                await self.sink.emitLog("Microphone input signal detected")
            }
        } else if tapInfo.count >= 45, !tapState.didLogInputSignal, !tapState.markDidWarnAboutSilentInput() {
            let tapInputDeviceName = tapState.tapInputDeviceName
            Task {
                await self.sink.emitLog(
                    "Microphone tap is active but the signal is near silent. Current input device: \(tapInputDeviceName)"
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

    private func updateDigitalSilenceDiagnostics(rawSamples: [Float], buffer: AVAudioPCMBuffer) {
#if os(macOS)
        guard !rawSamples.isEmpty else { return }

        let peakMagnitude = AudioTapSamples.peakMagnitude(rawSamples)
        guard peakMagnitude <= digitalSilencePeakThreshold else {
            _ = tapState.updateDigitalSilence(duration: 0, threshold: minimumDigitalSilenceRecoveryDuration, maxAttempts: maximumDigitalSilenceRecoveryAttempts)
            return
        }

        let sampleRate = buffer.format.sampleRate
        if sampleRate > 0 {
            let duration = Double(buffer.frameLength) / sampleRate
            let result = tapState.updateDigitalSilence(duration: duration, threshold: minimumDigitalSilenceRecoveryDuration, maxAttempts: maximumDigitalSilenceRecoveryAttempts)
            if result.shouldRecover {
                scheduleEngineRecovery(reason: "the microphone tap delivered only digital silence from \(result.deviceName)")
            }
        }
#endif
    }

    private func resampledTapSamples(from buffer: AVAudioPCMBuffer, rawSamples: [Float]) throws -> [Float] {
        do {
            let converted = try tapAudioConverter.resampleBuffer(buffer)
            if !converted.isEmpty {
                return converted
            }
        } catch {
            if !tapState.markDidLogFallbackResampler() {
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
        if !tapState.markDidLogFallbackResampler() {
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

    private func startAudioEngine(recoveryReason: String?) async throws {
        guard isRunning else { return }

        audioEngine = AVAudioEngine()
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Unknown input device"
        tapState.resetDiagnostics(deviceName: deviceName)
        installEngineConfigurationObserver()

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

        guard isRunning else {
            inputNode.removeTap(onBus: 0)
            return
        }

        audioEngine.prepare()
        try audioEngine.start()

        guard isRunning else {
            stopAudioEngine()
            return
        }

        let currentGeneration = tapState.incrementEngineGeneration()
        let tapFormatDescription = AudioTapSamples.describe(bufferFormat: inputFormat)

        await sink.resetInputLevel()
        if let recoveryReason {
            await sink.emitLog("Recovered microphone capture after \(recoveryReason)")
        }
        await sink.emitLog("Using microphone: \(deviceName)")
        await sink.emitLog("Microphone tap format: \(tapFormatDescription)")
        await sink.emitLog(recoveryReason == nil ? "Microphone capture started" : "Microphone capture resumed")
        scheduleTapWatchdog(engineGeneration: currentGeneration, tapFormatDescription: tapFormatDescription)
    }

    private func stopAudioEngine() {
        removeEngineConfigurationObserver()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
    }

    private func scheduleTapWatchdog(engineGeneration: UInt64, tapFormatDescription: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self,
                  self.isRunning,
                  self.tapState.engineStartGeneration == engineGeneration,
                  self.tapState.tapCallbackCount == 0 else { return }

            await self.sink.emitLog(
                "Microphone tap started but has not delivered any buffers after 2s. Tap format: \(tapFormatDescription)"
            )

            guard self.tapTimeoutRecoveryAttempts < self.maximumTapTimeoutRecoveryAttempts else { return }
            self.tapTimeoutRecoveryAttempts += 1
            self.scheduleEngineRecovery(reason: "the microphone tap did not deliver any buffers")
        }
    }

    private func scheduleEngineRecovery(reason: String) {
        guard isRunning, !isRecoveringEngine else { return }
        isRecoveringEngine = true

        engineRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.recoverAudioEngine(reason: reason)
        }
    }

    private func recoverAudioEngine(reason: String) async {
        defer {
            isRecoveringEngine = false
            engineRecoveryTask = nil
        }

        guard isRunning, !Task.isCancelled else { return }

        await sink.emitLog("Reconfiguring microphone capture because \(reason)")
        await turnDetector.reset()
        await sink.resetInputLevel()

        guard isRunning, !Task.isCancelled else { return }

        stopAudioEngine()
        audioEngine = AVAudioEngine()

        try? await Task.sleep(nanoseconds: engineRecoveryRestartDelayNanoseconds)

        guard isRunning, !Task.isCancelled else { return }

        do {
            try await startAudioEngine(recoveryReason: reason)
        } catch {
            guard isRunning, !Task.isCancelled else { return }
            await sink.emitLog("Failed to recover microphone capture: \(error.localizedDescription)")
        }
    }

    private func installObservers() {
        installEngineConfigurationObserver()
#if os(macOS)
        installCaptureDeviceObservers()
#endif
    }

    private func removeObservers() {
        removeEngineConfigurationObserver()
#if os(macOS)
        removeCaptureDeviceObservers()
#endif
    }

    private func installEngineConfigurationObserver() {
        removeEngineConfigurationObserver()
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleEngineRecovery(reason: "the audio hardware configuration changed")
        }
    }

    private func removeEngineConfigurationObserver() {
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
            self.engineConfigurationObserver = nil
        }
    }

#if os(macOS)
    private func installCaptureDeviceObservers() {
        guard captureDeviceConnectedObserver == nil, captureDeviceDisconnectedObserver == nil else { return }

        captureDeviceConnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
            self?.scheduleEngineRecovery(reason: "audio input device connected (\(device.localizedName))")
        }

        captureDeviceDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
            self?.scheduleEngineRecovery(reason: "audio input device disconnected (\(device.localizedName))")
        }
    }

    private func removeCaptureDeviceObservers() {
        if let captureDeviceConnectedObserver {
            NotificationCenter.default.removeObserver(captureDeviceConnectedObserver)
            self.captureDeviceConnectedObserver = nil
        }
        if let captureDeviceDisconnectedObserver {
            NotificationCenter.default.removeObserver(captureDeviceDisconnectedObserver)
            self.captureDeviceDisconnectedObserver = nil
        }
    }
#endif
}

private final class AudioTurnPipelineTapState: @unchecked Sendable {
    private let lock = NSLock()
    
    private var _tapInputDeviceName = "Unknown input device"
    private var _tapCallbackCount = 0
    private var _tapDebugLogCount = 0
    private var _tapRejectedDebugLogCount = 0
    private var _didLogInputSignal = false
    private var _didWarnAboutSilentInput = false
    private var _didLogFallbackResampler = false
    private var _digitalSilenceDuration: TimeInterval = 0
    private var _digitalSilenceRecoveryAttempts = 0
    private var _engineStartGeneration: UInt64 = 0

    var tapInputDeviceName: String {
        lock.lock(); defer { lock.unlock() }; return _tapInputDeviceName
    }

    var tapCallbackCount: Int {
        lock.lock(); defer { lock.unlock() }; return _tapCallbackCount
    }
    
    var didLogInputSignal: Bool {
        lock.lock(); defer { lock.unlock() }; return _didLogInputSignal
    }

    var didWarnAboutSilentInput: Bool {
        lock.lock(); defer { lock.unlock() }; return _didWarnAboutSilentInput
    }

    var digitalSilenceRecoveryAttempts: Int {
        lock.lock(); defer { lock.unlock() }; return _digitalSilenceRecoveryAttempts
    }

    var engineStartGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _engineStartGeneration
    }

    func resetDiagnostics(deviceName: String) {
        lock.lock()
        _tapInputDeviceName = deviceName
        _tapCallbackCount = 0
        _tapDebugLogCount = 0
        _tapRejectedDebugLogCount = 0
        _didLogInputSignal = false
        _didWarnAboutSilentInput = false
        _didLogFallbackResampler = false
        _digitalSilenceDuration = 0
        lock.unlock()
    }

    func resetDigitalSilenceRecovery() {
        lock.lock()
        _digitalSilenceRecoveryAttempts = 0
        lock.unlock()
    }

    func incrementEngineGeneration() -> UInt64 {
        lock.lock()
        _engineStartGeneration &+= 1
        let gen = _engineStartGeneration
        lock.unlock()
        return gen
    }

    func registerTapCallback() -> (count: Int, shouldLogDebug: Bool) {
        lock.lock()
        _tapCallbackCount += 1
        let count = _tapCallbackCount
        let shouldLog = _tapDebugLogCount < 3
        if shouldLog { _tapDebugLogCount += 1 }
        lock.unlock()
        return (count, shouldLog)
    }

    func registerRejectedTap() -> Bool {
        lock.lock()
        let shouldLog = _tapRejectedDebugLogCount < 3
        if shouldLog { _tapRejectedDebugLogCount += 1 }
        lock.unlock()
        return shouldLog
    }

    func markDidLogInputSignal() -> Bool {
        lock.lock()
        let alreadyLogged = _didLogInputSignal
        _didLogInputSignal = true
        lock.unlock()
        return alreadyLogged
    }

    func markDidWarnAboutSilentInput() -> Bool {
        lock.lock()
        let alreadyWarned = _didWarnAboutSilentInput
        _didWarnAboutSilentInput = true
        lock.unlock()
        return alreadyWarned
    }

    func markDidLogFallbackResampler() -> Bool {
        lock.lock()
        let alreadyLogged = _didLogFallbackResampler
        _didLogFallbackResampler = true
        lock.unlock()
        return alreadyLogged
    }

    func updateDigitalSilence(duration: TimeInterval, threshold: TimeInterval, maxAttempts: Int) -> (shouldRecover: Bool, deviceName: String) {
        lock.lock()
        defer { lock.unlock() }

        if duration == 0 {
            _digitalSilenceDuration = 0
            return (false, "")
        }

        _digitalSilenceDuration += duration

        if _digitalSilenceDuration >= threshold, !_didLogInputSignal, _digitalSilenceRecoveryAttempts < maxAttempts {
            _digitalSilenceRecoveryAttempts += 1
            _didWarnAboutSilentInput = true
            return (true, _tapInputDeviceName)
        }
        return (false, "")
    }
}

private final class AudioTurnPipelineCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
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

    static func peakMagnitude(_ samples: [Float]) -> Float {
        samples.reduce(Float.zero) { currentPeak, sample in
            max(currentPeak, abs(sample))
        }
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

    private static func mixInterleaved(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
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
