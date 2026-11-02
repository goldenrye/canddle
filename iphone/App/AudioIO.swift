import AVFoundation
import Foundation

struct AudioRuntimeError: Error, LocalizedError, Sendable {
    let detail: String
    var errorDescription: String? { detail }
}

/// Shared by the real-time input tap and the call actor; buffers are always bounded.
final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var playbackCount = 0
    private var muted = false
    private var stopped = false
    private var failure: AudioRuntimeError?

    func push(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if frames.count == 5 { frames.removeFirst() }
        frames.append(muted ? VoiceProtocol.silence : frame)
    }

    func pop() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard !stopped else {
            throw AudioRuntimeError(detail: "Microphone capture queue was stopped.")
        }
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        return muted ? VoiceProtocol.silence : frame
    }

    func mute(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
        frames.removeAll()
    }

    func reservePlayback() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, playbackCount < 5 else { return false }
        playbackCount += 1
        return true
    }

    func played() {
        lock.lock(); defer { lock.unlock() }
        playbackCount = max(0, playbackCount - 1)
    }

    func fail(_ error: AudioRuntimeError) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = error }
    }

    func discardCapture() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        frames.removeAll()
    }
}

final class PCMConverter {
    private var converter: AVAudioConverter
    let format: AVAudioFormat
    let queue: AudioBuffer
    var partial = Data()

    init(from: AVAudioFormat, to: AVAudioFormat, queue: AudioBuffer) throws {
        guard from.sampleRate > 0, from.channelCount > 0,
              let converter = AVAudioConverter(from: from, to: to) else {
            throw AudioRuntimeError(detail: "Could not configure microphone PCM conversion.")
        }
        self.converter = converter
        format = to
        self.queue = queue
    }

    func consume(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0 else { return }
        // Voice processing / route negotiation may change the format after graph
        // setup. Resample the delivered buffer, not a stale pre-start format.
        if !input.format.isEqual(converter.inputFormat) {
            guard input.format.sampleRate > 0, input.format.channelCount > 0,
                  let replacement = AVAudioConverter(from: input.format, to: format) else {
                queue.fail(AudioRuntimeError(detail: "The microphone delivered an unsupported PCM format."))
                return
            }
            converter = replacement
            partial.removeAll(keepingCapacity: true)
            queue.discardCapture()
        }
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            queue.fail(AudioRuntimeError(detail: "Could not allocate the microphone conversion buffer."))
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else {
            let source = input.format
            queue.fail(AudioRuntimeError(detail: "Microphone PCM conversion failed "
                + "(error \(error?.code ?? 0), status \(status.rawValue), "
                + "\(Int(source.sampleRate)) Hz, \(source.channelCount) channels)."))
            return
        }
        // A resampler can consume a short first buffer without producing output.
        guard output.frameLength > 0 else { return }
        guard let samples = output.floatChannelData?[0] else {
            queue.fail(AudioRuntimeError(detail: "Microphone conversion returned no Float32 samples."))
            return
        }
        for i in 0..<Int(output.frameLength) {
            let sample = samples[i].isFinite ? min(1, max(-1, samples[i])) : 0
            let bits = UInt16(bitPattern: Int16(clamping: Int((sample * 32767).rounded())))
            partial.append(UInt8(truncatingIfNeeded: bits))
            partial.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        while partial.count >= VoiceProtocol.frameSize {
            queue.push(Data(partial.prefix(VoiceProtocol.frameSize)))
            partial = Data(partial.dropFirst(VoiceProtocol.frameSize))
        }
    }
}

struct AudioStartupError: LocalizedError {
    let stage: String
    let code: Int

    var errorDescription: String? {
        "Could not \(stage) (audio error \(code)). Check microphone access and the audio route."
    }
}

/// Notification callbacks can prohibit restart before the main actor receives
/// the corresponding interruption/background cleanup.
final class AudioRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permitted = false

    func set(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        permitted = value
    }

    var allowsRestart: Bool {
        lock.lock(); defer { lock.unlock() }
        return permitted
    }
}

@MainActor
final class AudioEngineRecovery {
    let gate = AudioRecoveryGate()
    private var attempts = 0
    private var began: TimeInterval?
    private var nextAttempt: TimeInterval = 0
    private var lastFailure = ""

    func begin() {
        attempts = 0
        began = nil
        nextAttempt = 0
        lastFailure = ""
        gate.set(true)
    }

    func stop() { gate.set(false) }

    func ensureRunning(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       isRunning: () -> Bool, restart: () throws -> Void) throws -> Bool {
        guard gate.allowsRestart else {
            throw AudioRuntimeError(detail: "Audio stopped by an interruption, unavailable route, or call shutdown.")
        }
        if isRunning() {
            began = nil
            return true
        }
        if began == nil { began = now }
        // A fixed per-call retry budget also bounds repeated stop/start cycles.
        guard attempts < 3, now - began! < 2 else {
            throw AudioRuntimeError(detail: "The audio engine could not stay running after \(attempts) restart attempts."
                + (lastFailure.isEmpty ? "" : " \(lastFailure)"))
        }
        guard now >= nextAttempt else { return false }
        attempts += 1
        nextAttempt = now + 0.25
        do {
            try restart()
        } catch {
            lastFailure = (error as? AudioRuntimeError)?.detail
                ?? "Audio restart error \((error as NSError).code)."
        }
        guard gate.allowsRestart else {
            throw AudioRuntimeError(detail: "Audio restart canceled by an interruption or call shutdown.")
        }
        if isRunning() {
            began = nil
            return true
        }
        return false
    }
}

#if os(iOS)
import UIKit

@MainActor
final class AudioIO {
    // Instantiate after session activation so its initial I/O format is current.
    private lazy var engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var queue = AudioBuffer()
    private let wireFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private let recovery = AudioEngineRecovery()
    private var sessionObservers: [NSObjectProtocol] = []
    private var tapped = false
    private var active = false
    private var muted = false

    static func permission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    private var managedByCallKit = false

    func start(managedByCallKit: Bool = false) throws {
        self.managedByCallKit = managedByCallKit
        var stage = "configure the audio session"
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
            stage = "activate the audio session"
            if !managedByCallKit { try session.setActive(true) }
            active = true
            recovery.begin()
            observeSession()
            let input = engine.inputNode
            stage = "enable voice processing"
            try input.setVoiceProcessingEnabled(true)
            stage = "configure microphone conversion"
            try installCapture()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: wireFormat)
            engine.prepare()
            stage = "start the audio engine"
            guard recovery.gate.allowsRestart else { throw VoiceError.ended }
            try engine.start()
            player.play()
        } catch {
            stop()
            throw AudioStartupError(stage: stage, code: (error as NSError).code)
        }
    }

    private func installCapture() throws {
        let input = engine.inputNode
        let converter = try PCMConverter(from: input.outputFormat(forBus: 0), to: wireFormat, queue: queue)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            converter.consume(buffer)
        }
        tapped = true
    }

    private func ensureRunning() throws -> Bool {
        try recovery.ensureRunning(isRunning: { self.engine.isRunning }) {
            // Keep encryption state intact, but discard queued audio from the old
            // graph. Old tap/playback callbacks retain their old, stopped queue.
            self.player.stop()
            self.engine.stop()
            if self.tapped {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapped = false
            }
            self.queue.stop()
            self.queue = AudioBuffer()
            self.queue.mute(self.muted)
            guard self.recovery.gate.allowsRestart else { throw VoiceError.ended }
            try self.installCapture()
            self.engine.disconnectNodeOutput(self.player)
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: self.wireFormat)
            let output = self.engine.outputNode
            let hardware = output.inputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
                throw AudioRuntimeError(detail: "The speaker route was not ready during audio restart.")
            }
            self.engine.connect(self.engine.mainMixerNode, to: output, format: hardware)
            self.engine.prepare()
            guard self.recovery.gate.allowsRestart else { throw VoiceError.ended }
            try self.engine.start()
            self.player.play()
        }
    }

    private func observeSession() {
        let gate = recovery.gate
        var events = [AVAudioSession.interruptionNotification,
                      AVAudioSession.routeChangeNotification,
                      AVAudioSession.mediaServicesWereLostNotification,
                      AVAudioSession.mediaServicesWereResetNotification]
        if !managedByCallKit { events.append(UIApplication.didEnterBackgroundNotification) }
        for event in events {
            sessionObservers.append(NotificationCenter.default.addObserver(
                forName: event, object: nil, queue: nil
            ) { note in
                let info = note.userInfo ?? [:]
                switch note.name {
                case AVAudioSession.interruptionNotification:
                    if let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                       AVAudioSession.InterruptionType(rawValue: raw) == .began {
                        gate.set(false)
                    }
                case AVAudioSession.routeChangeNotification:
                    if let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                       AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                        gate.set(false)
                    }
                default: gate.set(false)
                }
            })
        }
    }

    func nextFrame() throws -> Data? {
        guard try ensureRunning() else { return nil }
        return try queue.pop()
    }

    func play(_ frame: Data) throws {
        guard try ensureRunning() else { return }
        guard frame.count == 640 else {
            throw AudioRuntimeError(detail: "Playback received an invalid PCM frame size.")
        }
        guard queue.reservePlayback() else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: 320),
              let samples = buffer.floatChannelData?[0] else {
            queue.played()
            throw AudioRuntimeError(detail: "Could not allocate the speaker playback buffer.")
        }
        buffer.frameLength = 320
        let bytes = [UInt8](frame)
        for i in 0..<320 {
            let bits = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
            samples[i] = Float(Int16(bitPattern: bits)) / 32768
        }
        let queue = queue
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in queue.played() }
    }

    func mute(_ value: Bool) { muted = value; queue.mute(value) }

    func stop() {
        recovery.stop()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
        queue.stop()
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        player.stop()
        engine.stop()
        if active {
            if !managedByCallKit {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            active = false
        }
    }
}
#endif
