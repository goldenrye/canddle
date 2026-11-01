import CryptoKit
import Foundation

// Compiled on macOS with Core/*.swift and App/LobbyStore.swift. Storage is
// injected so these lifecycle checks never read or write the user's Keychain.
@main
struct LobbyStoreChecks {
    struct Input: Decodable {
        let address: String
        let token: String
        let mode: String
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async {
        do {
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let settings = try RelaySettings(address: input.address, token: input.token, testLoopback: true)
            var aliceSaved = LobbyIdentity(secret: Curve25519.Signing.PrivateKey().rawRepresentation, trusted: [:])
            var bobSaved = LobbyIdentity(secret: Curve25519.Signing.PrivateKey().rawRepresentation, trusted: [:])
            let alice = LobbyStore(loadIdentity: { aliceSaved }, saveIdentity: {
                if input.mode == "caller-save-failure" { throw VoiceError.ended }
                aliceSaved = $0
            })
            let bob = LobbyStore(loadIdentity: { bobSaved }, saveIdentity: {
                if input.mode == "requester-save-failure" { throw VoiceError.ended }
                bobSaved = $0
            })
            alice.name = "Alice"
            bob.name = "Bob"
            var aliceInvitation: String?
            var bobInvitation: String?
            var calls: [Task<String, Error>] = []
            let audioA = Relay(settings), audioB = Relay(settings)
            defer {
                alice.disconnect(); bob.disconnect()
                calls.forEach { $0.cancel() }
                audioA.stop(); audioB.stop()
            }
            func handoff(_ relay: Relay, _ text: String) {
                guard input.mode == "handoff" else { return }
                // Start directly from the callback, as CallStore does, while the
                // lobby reader is being canceled and its socket is closing.
                calls.append(Task { @MainActor in
                    try Task.checkCancellation()
                    let code = try await relay.connect(CallInvitation(text), waiting: {})
                    try await relay.transmit(VoiceProtocol.silence)
                    let frame = try await relay.listen()
                    precondition(frame == VoiceProtocol.silence)
                    return code
                })
            }
            alice.connect(settings) { aliceInvitation = $0; handoff(audioA, $0) }
            bob.connect(settings) { bobInvitation = $0; handoff(audioB, $0) }
            try await wait { alice.online && bob.online }
            alice.announce()
            try await wait { bob.offers.count == 1 && !alice.sending }
            bob.request(bob.offers[0])
            try await wait { alice.candidates.count == 1 && !bob.sending }
            let candidate = alice.candidates[0]
            precondition(candidate.exchange.code == bob.joining?.code)
            precondition(alice.trustedName(candidate.exchange.request.identity) == nil)
            // Approval cannot bypass the requester's confirmation.
            alice.approve(candidate)
            precondition(alice.approving == nil && aliceInvitation == nil && bobInvitation == nil)
            if input.mode == "cancel" {
                bob.cancelRequest()
                try await wait { alice.candidates.isEmpty && !bob.waiting }
                alice.cancelRequest()
                try await wait { bob.offers.isEmpty && !alice.waiting }
                precondition(aliceInvitation == nil && bobInvitation == nil)
            } else if input.mode == "reject" {
                alice.reject(candidate)
                try await wait { !bob.waiting }
                precondition(aliceInvitation == nil && bobInvitation == nil)
            } else if input.mode == "disconnect" {
                alice.disconnect()
                try await wait { !bob.waiting && bob.offers.isEmpty }
                precondition(bobInvitation == nil)
            } else if input.mode == "expire" {
                try await wait { !alice.waiting && !bob.waiting }
                precondition(aliceInvitation == nil && bobInvitation == nil)
            } else {
                bob.confirmCaller()
                if input.mode == "requester-save-failure" {
                    precondition(!bob.confirmed && bobSaved.trusted.isEmpty)
                    precondition(bob.status.contains("No confirmation was sent"))
                } else {
                    try await wait { alice.candidates.first?.confirmed == true && !bob.sending }
                    alice.approve(alice.candidates[0])
                    if input.mode == "caller-save-failure" {
                        precondition(alice.approving == nil && aliceSaved.trusted.isEmpty)
                        precondition(alice.status.contains("Nothing was sent"))
                    } else {
                        try await wait { aliceInvitation != nil && bobInvitation != nil }
                        precondition(aliceInvitation == bobInvitation)
                        if input.mode == "handoff" {
                            precondition(calls.count == 2)
                            let first = try await calls[0].value
                            let second = try await calls[1].value
                            precondition(first == second)
                            audioA.stop(); audioB.stop()
                        }
                        precondition(!alice.active && !bob.active && !alice.waiting && !bob.waiting)
                        precondition(aliceSaved.trusted.count == 1 && bobSaved.trusted.count == 1)
                        let bobKey = candidate.exchange.request.identity
                        // Reload the saved identity and trust. Names can change; trust is key-bound.
                        let restored = LobbyStore(loadIdentity: { aliceSaved }, saveIdentity: { aliceSaved = $0 })
                        restored.connect(settings) { _ in preconditionFailure("Unexpected call") }
                        try await wait { restored.online }
                        precondition(restored.trustedName(bobKey) == "Bob")
                        precondition(restored.trustedName(VoiceProtocol.base64(
                            Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
                        )) == nil)
                        restored.disconnect()
                        restored.forgetPeers()
                        precondition(aliceSaved.trusted.isEmpty && restored.trusted.isEmpty)
                    }
                }
            }
            print("PASS lobby state \(input.mode)")
        } catch {
            print("FAIL \(String(describing: type(of: error)))")
            exit(1)
        }
    }
}
