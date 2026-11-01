import CryptoKit
import Foundation

/// Compiled with Core/*.swift on macOS to exercise the same transport without a microphone.
@main
struct Probe {
    struct Input: Decodable {
        let address: String
        let token: String
        let invitation: String
        let root: String?
        let cancel: Bool?
        let pairing: String?
        let lobby: String?
    }

    @MainActor static func main() async {
        do {
            let input = try JSONDecoder().decode(
                Input.self, from: FileHandle.standardInput.readDataToEndOfFile()
            )
            let root = try input.root.map {
                try RelaySettings.certificate(Data(contentsOf: URL(fileURLWithPath: $0)))
            }
            if let raw = input.pairing {
                let ticket = try PairingTicket.parse(raw)
                let relay = Relay(try RelaySettings(address: ticket.relay, token: ticket.code, root: root))
                let cancellation = Task { @MainActor in
                    if input.cancel == true {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        relay.stop()
                    }
                }
                defer { cancellation.cancel(); relay.stop() }
                let token = try await relay.redeem(ticket)
                guard token == input.token else { throw VoiceError.token }
                print("PASS pairing")
                return
            }
            let relay = Relay(try RelaySettings(
                address: input.address, token: input.token, root: root, testLoopback: true
            ))
            defer { relay.stop() }
            let cancellation = Task { @MainActor in
                if input.cancel == true {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    relay.stop()
                }
            }
            defer { cancellation.cancel() }
            if let role = input.lobby {
                let signing = Curve25519.Signing.PrivateKey()
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                try await relay.openLobby(identity: signing, name: role)
                let exchange: LobbyExchange
                if role == "caller" {
                    let offer = try LobbyOffer.create(identity: signing, name: role, ephemeral: ephemeral)
                    try await relay.lobbySend(offer.message)
                    guard try await relay.lobbyReceive(seconds: 10) == offer.message else {
                        throw VoiceError.packet
                    }
                    let request = try LobbyRequest(await relay.lobbyReceive(seconds: 10), offer: offer)
                    exchange = try LobbyExchange(offer: offer, request: request, ephemeral: ephemeral, caller: true)
                    let confirm = try await relay.lobbyReceive(seconds: 10)
                    guard confirm["type"] == "confirm", confirm["call"] == offer.id,
                          confirm["request"] == request.id, let proof = confirm["proof"] else {
                        throw VoiceError.packet
                    }
                    try exchange.verifyConfirmation(proof)
                    try await relay.lobbySend([
                        "type": "approve", "call": offer.id, "request": request.id,
                        "box": exchange.seal(CallInvitation(input.invitation))
                    ])
                    let result = try await relay.lobbyReceive(seconds: 10)
                    guard result["type"] == "granted", result["request"] == request.id else {
                        throw VoiceError.packet
                    }
                } else {
                    let offer = try LobbyOffer(await relay.lobbyReceive(seconds: 10))
                    let request = try LobbyRequest.create(
                        offer: offer, identity: signing, name: role, ephemeral: ephemeral
                    )
                    exchange = try LobbyExchange(offer: offer, request: request, ephemeral: ephemeral, caller: false)
                    try await relay.lobbySend(request.message)
                    try await relay.lobbySend([
                        "type": "confirm", "call": offer.id, "request": request.id,
                        "proof": exchange.confirmation()
                    ])
                    let result = try await relay.lobbyReceive(seconds: 10)
                    guard result["type"] == "approve", result["call"] == offer.id,
                          result["request"] == request.id, let box = result["box"],
                          try exchange.open(box).text == input.invitation else { throw VoiceError.peer }
                }
                // Test peers automatically confirm; the production UI requires human approval.
                print("PASS lobby \(exchange.code)")
                return
            }
            let code = try await relay.connect(CallInvitation(input.invitation), waiting: {})
            for _ in 0..<10 {
                try await relay.transmit(Data((0..<320).flatMap { _ in [UInt8(0x12), 0x34] }))
                let frame = try await relay.listen()
                guard frame == Data((0..<320).flatMap { _ in [UInt8(0x56), 0x78] }) else {
                    throw VoiceError.packet
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            print("PASS \(code)")
        } catch {
            print("FAIL \(String(describing: type(of: error)))")
            exit(1)
        }
    }
}
