import AVFoundation
import Foundation

@main
struct AudioChecks {
    @MainActor static func main() throws {
        try recoveryChecks()
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for rate in [8000.0, 16000, 44100, 48000] {
            for channels: AVAudioChannelCount in [1, 2] {
                for size: AVAudioFrameCount in [1, 128, 320, 1024] {
                    let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                    let queue = AudioBuffer()
                    let converter = try PCMConverter(from: source, to: target, queue: queue)
                    var count = 0
                    for _ in 0..<100 {
                        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: size)!
                        buffer.frameLength = size
                        for channel in 0..<Int(channels) {
                            for index in 0..<Int(size) { buffer.floatChannelData![channel][index] = 0.25 }
                        }
                        converter.consume(buffer)
                        do {
                            while let frame = try queue.pop() {
                                precondition(frame.count == 640)
                                count += 1
                            }
                        } catch {
                            print("FAIL rate=\(rate) channels=\(channels) size=\(size): \(error)")
                            throw error
                        }
                    }
                    if size >= 128 { precondition(count > 0) }
                }
            }
        }
        // Audio routes can renegotiate between graph setup and the first tap.
        let queue = AudioBuffer()
        let initial = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let converter = try PCMConverter(from: initial, to: target, queue: queue)
        for (rate, channels): (Double, AVAudioChannelCount) in [(48000, 1), (44100, 1), (16000, 2), (48000, 1)] {
            let delivered = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let buffer = AVAudioPCMBuffer(pcmFormat: delivered, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for channel in 0..<Int(channels) {
                for index in 0..<1024 { buffer.floatChannelData![channel][index] = 0 }
            }
            converter.consume(buffer)
            do {
                while let frame = try queue.pop() { precondition(frame == VoiceProtocol.silence) }
            } catch {
                FileHandle.standardError.write(Data("FAIL delivered format changed to \(rate): \(error)\n".utf8))
                exit(1)
            }
        }
        // Empty taps during resampler priming are not fatal.
        let empty = AVAudioPCMBuffer(pcmFormat: initial, frameCapacity: 1)!
        converter.consume(empty)
        let emptyResult = try queue.pop()
        precondition(emptyResult == nil)
        // Preserve the first capture error across the audio callback / main actor.
        let failed = AudioBuffer()
        failed.fail(AudioRuntimeError(detail: "test conversion error"))
        failed.fail(AudioRuntimeError(detail: "later error"))
        do {
            _ = try failed.pop()
            preconditionFailure("Capture failure must propagate")
        } catch let error as AudioRuntimeError {
            precondition(error.detail == "test conversion error")
        }
        let bounded = AudioBuffer()
        for _ in 0..<10 { bounded.push(Data(repeating: 1, count: 640)) }
        var buffered = 0
        while let _ = try bounded.pop() { buffered += 1 }
        precondition(buffered == 5)
        bounded.mute(true)
        bounded.push(Data(repeating: 1, count: 640))
        let muted = try bounded.pop()
        precondition(muted == VoiceProtocol.silence)
        bounded.stop()
        do {
            _ = try bounded.pop()
            preconditionFailure("Stopped capture must not resume")
        } catch is AudioRuntimeError {}
        print("PASS audio: conversion, queues, bounded engine recovery, interruption and shutdown gates")
    }

    @MainActor static func recoveryChecks() throws {
        let recovery = AudioEngineRecovery()
        var running = true
        var restarts = 0
        let restart = { restarts += 1; running = true }
        recovery.begin()
        let initial = try recovery.ensureRunning(now: 0, isRunning: { running }, restart: restart)
        precondition(initial && restarts == 0)
        // A configuration change stops the engine after successful startup.
        running = false
        let recovered = try recovery.ensureRunning(now: 1, isRunning: { running }, restart: restart)
        precondition(recovered && restarts == 1)
        // Capture and playback checking the same state must not restart twice.
        let playback = try recovery.ensureRunning(now: 1, isRunning: { running }, restart: restart)
        precondition(playback && restarts == 1)
        recovery.gate.set(false)
        running = false
        do {
            _ = try recovery.ensureRunning(now: 2, isRunning: { running }, restart: restart)
            preconditionFailure("An interruption must prohibit restart")
        } catch is AudioRuntimeError {}
        precondition(restarts == 1)
        recovery.begin()
        recovery.stop()
        do {
            _ = try recovery.ensureRunning(now: 3, isRunning: { running }, restart: restart)
            preconditionFailure("A stopped call must not restart")
        } catch is AudioRuntimeError {}
        precondition(restarts == 1)
        // Failed restart calls are spaced out, then terminate at a fixed budget.
        recovery.begin()
        restarts = 0
        let failure: () throws -> Void = {
            restarts += 1
            throw AudioRuntimeError(detail: "test restart failure")
        }
        let first = try recovery.ensureRunning(now: 10, isRunning: { false }, restart: failure)
        let throttled = try recovery.ensureRunning(now: 10.1, isRunning: { false }, restart: failure)
        precondition(!first && !throttled && restarts == 1)
        _ = try recovery.ensureRunning(now: 10.25, isRunning: { false }, restart: failure)
        _ = try recovery.ensureRunning(now: 10.5, isRunning: { false }, restart: failure)
        do {
            _ = try recovery.ensureRunning(now: 10.75, isRunning: { false }, restart: failure)
            preconditionFailure("Repeated failures must terminate")
        } catch let error as AudioRuntimeError {
            precondition(error.detail.contains("test restart failure"))
        }
        precondition(restarts == 3)
        // A late retry cannot keep the recovery window alive indefinitely.
        recovery.begin()
        _ = try recovery.ensureRunning(now: 20, isRunning: { false }, restart: failure)
        do {
            _ = try recovery.ensureRunning(now: 22.1, isRunning: { false }, restart: failure)
            preconditionFailure("Recovery must have a deadline")
        } catch is AudioRuntimeError {}
        precondition(restarts == 4)
        // An interruption arriving inside the restart must prevent normal return.
        recovery.begin()
        do {
            _ = try recovery.ensureRunning(now: 30, isRunning: { running }) {
                recovery.gate.set(false)
                running = true
            }
            preconditionFailure("Interrupted recovery must fail closed")
        } catch is AudioRuntimeError {}
    }
}
