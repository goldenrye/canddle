import Foundation

/// CallKit activation permits local ringback, not microphone capture.
struct OutgoingCallAudio {
    enum Phase { case idle, dialing, admitted, connected }
    private(set) var phase: Phase = .idle
    private(set) var active = false
    var shouldPlayRingback: Bool { active && phase == .dialing }

    mutating func start(admitted: Bool) {
        phase = admitted ? .admitted : .dialing
        active = false
    }
    mutating func admit() { if phase == .dialing { phase = .admitted } }
    mutating func activate() { active = true }
    mutating func deactivate() { active = false }
    mutating func reset() { self = Self() }

    /// Report the first media connection only, never a subsequent ICE recovery.
    mutating func connect() -> Bool {
        guard phase == .admitted else { return false }
        phase = .connected
        return true
    }
}

enum RingbackTone {
    static let sampleRate = 16000
    static let duration = 6
    static let soundingSeconds = 2

    static func sample(_ index: Int) -> Int16 {
        guard index >= 0, index < sampleRate * soundingSeconds else { return 0 }
        let time = Double(index) / Double(sampleRate)
        let edge = min(time, Double(soundingSeconds) - time)
        let envelope = min(1, edge / 0.01)
        let value = 0.12 * envelope * (sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time))
        return Int16(value * Double(Int16.max))
    }

    /// Two seconds of local ringing followed by four seconds of silence.
    /// A standard PCM WAV avoids audio-engine/input-node startup while dialing.
    static func wave() -> Data {
        let size = sampleRate * duration * 2
        var data = Data()
        data.reserveCapacity(44 + size)
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); word(UInt32(36 + size)); text("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(sampleRate)); word(UInt32(sampleRate * 2))
        word(UInt16(2)); word(UInt16(16)); text("data"); word(UInt32(size))
        for index in 0..<(sampleRate * duration) { word(sample(index)) }
        return data
    }
}
