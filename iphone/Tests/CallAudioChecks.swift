import AVFoundation
import Foundation

@main struct CallAudioChecks {
    static func main() throws {
        var state = OutgoingCallAudio()
        state.activate()
        precondition(!state.shouldPlayRingback && !state.connect()) // Incoming calls never ring back.
        state.reset()
        state.start(admitted: false)
        precondition(!state.shouldPlayRingback) // CallKit must activate first.
        state.activate()
        precondition(state.shouldPlayRingback)
        state.admit()
        precondition(!state.shouldPlayRingback)
        precondition(state.connect())
        precondition(!state.connect()) // ICE reconnect must not report a second answered call.
        state.deactivate()
        state.activate()
        precondition(!state.shouldPlayRingback && !state.connect())

        state.reset()
        state.start(admitted: false)
        state.admit() // Answer can arrive before audio activation.
        state.activate()
        precondition(!state.shouldPlayRingback && state.connect())
        state.reset()
        state.start(admitted: true) // In-app join, no incoming CallKit UI.
        state.activate()
        precondition(!state.shouldPlayRingback && state.connect())
        for activated in [false, true] {
            state.reset()
            state.start(admitted: false)
            if activated { state.activate() }
            state.reset() // Cancel, decline, expiry, reset, or signaling failure.
            state.activate() // Late callbacks cannot restart tone or report connected.
            state.admit()
            precondition(!state.shouldPlayRingback && !state.connect())
        }

        let wave = RingbackTone.wave()
        precondition(wave.count == 44 + 16000 * 6 * 2)
        precondition(String(decoding: wave.prefix(4), as: UTF8.self) == "RIFF")
        precondition(String(decoding: wave[8..<12], as: UTF8.self) == "WAVE")
        precondition(RingbackTone.sample(0) == 0 && RingbackTone.sample(32000) == 0)
        let samples = (0..<32000).map(RingbackTone.sample)
        precondition(samples.contains { abs(Int($0)) > 5000 })
        precondition(samples.allSatisfy { abs(Int($0)) < 8000 }) // Bounded tone level.
        precondition(wave[(44 + 32000 * 2)...].allSatisfy { $0 == 0 }) // Four-second silence.
        // Decode the generated resource without starting capture or playback.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("canddle-ringback-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try wave.write(to: file)
        let decoded = try AVAudioFile(forReading: file)
        precondition(decoded.length == 96000 && decoded.fileFormat.sampleRate == 16000)
        precondition(decoded.fileFormat.channelCount == 1)
        print("PASS outgoing ringback: activation, early answer, connection, cancellation and bounded PCM cadence")
    }
}
