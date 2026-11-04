import CryptoKit
import Foundation

@main
struct ProtocolChecks {
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "Expected rejection", code: 1)
    }

    static func main() throws {
        let invite = try CallInvitation.generate()
        let parsed = try CallInvitation(invite.text)
        precondition(parsed.text == invite.text)
        for value in ["", "vp1.a.b", invite.text + "."] {
            try rejects { _ = try CallInvitation(value) }
        }
        let a = KeyExchange(invite), b = KeyExchange(invite)
        var alice = try a.authenticate(b.hello())
        var bob = try b.authenticate(a.hello())
        precondition(alice.code == bob.code)
        try rejects { _ = try a.authenticate(a.hello()) }
        try rejects { _ = try a.authenticate(KeyExchange(CallInvitation.generate()).hello()) }
        let packet = try alice.seal(VoiceProtocol.confirmation)
        var tampered = packet
        tampered[tampered.count - 1] ^= 1
        try rejects { _ = try bob.open(tampered) }
        let confirmation = try bob.open(packet)
        precondition(confirmation == VoiceProtocol.confirmation)
        try rejects { _ = try bob.open(packet) }
        try rejects { _ = try alice.open(packet) }
        let first = try alice.seal(Data([1]) + VoiceProtocol.silence)
        let second = try alice.seal(Data([1]) + VoiceProtocol.silence)
        try rejects { _ = try bob.open(second) }
        _ = try bob.open(first)
        _ = try bob.open(second)
        try rejects { _ = try bob.open(Data(repeating: 0, count: 666)) }
        try rejects { _ = try alice.seal(Data(repeating: 0, count: 642)) }
        for url in ["ws://example.com/relay", "wss://a:b@example.com/relay",
                    "wss://example.com/relay?", "wss://example.com/relay#",
                    "wss://example.com/%72elay", "wss://example.com:0/relay"] {
            try rejects { _ = try RelaySettings(address: url, token: String(repeating: "a", count: 40)) }
        }
        try rejects { _ = try RelaySettings.certificate(Data("invalid".utf8)) }
        let capability = VoiceProtocol.base64(Data(repeating: 1, count: 32))
        let qr = "{\"type\":\"vpcomm-pair\",\"v\":1,\"relay\":\"wss://example.com/relay\","
            + "\"code\":\"\(capability)\"}"
        let ticket = try PairingTicket.parse(qr)
        precondition(ticket.code == capability)
        for bad in ["[]", invite.text, qr.replacingOccurrences(of: "wss:", with: "ws:"),
                    qr.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
                    qr.replacingOccurrences(of: capability, with: "short"),
                    String(repeating: "x", count: 1025)] {
            try rejects { _ = try PairingTicket.parse(bad) }
        }
        let signingA = Curve25519.Signing.PrivateKey(), signingB = Curve25519.Signing.PrivateKey()
        let ephemeralA = Curve25519.KeyAgreement.PrivateKey(), ephemeralB = Curve25519.KeyAgreement.PrivateKey()
        let offer = try LobbyOffer.create(identity: signingA, name: "Alice", ephemeral: ephemeralA)
        let receiver = VoiceProtocol.base64(signingB.publicKey.rawRepresentation)
        let push: [AnyHashable: Any] = [
            "v": 1, "scope": "wss://example.com/relay", "recipient": receiver,
            "offer": offer.message, "expires": 1030.0
        ]
        let parsedPush = try IncomingCallPush(push, scope: "wss://example.com/relay",
                                              recipient: receiver, now: 1000)
        precondition(parsedPush.offer.message == offer.message)
        for (field, value): (AnyHashable, Any) in [
            ("v", 2), ("scope", "wss://other.example/relay"), ("recipient", offer.identity),
            ("expires", 999.0), ("expires", 1061.0), ("expires", Double.nan),
            ("offer", ["type": "offer"]), ("offer", offer.message.merging(["name": "Impostor"]) { _, b in b })
        ] {
            var bad = push
            bad[field] = value
            try rejects {
                _ = try IncomingCallPush(bad, scope: "wss://example.com/relay", recipient: receiver, now: 1000)
            }
        }
        let request = try LobbyRequest.create(offer: offer, identity: signingB, name: "Bob", ephemeral: ephemeralB)
        let direct = try LobbyOffer.create(identity: signingA, name: "Alice", ephemeral: ephemeralA, target: receiver)
        var stripped = direct.message
        stripped.removeValue(forKey: "target")
        try rejects { _ = try LobbyOffer(stripped) }
        var retargeted = direct.message
        retargeted["target"] = VoiceProtocol.base64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        try rejects { _ = try LobbyOffer(retargeted) }
        try rejects {
            _ = try LobbyRequest.create(offer: direct, identity: Curve25519.Signing.PrivateKey(),
                                        name: "Outsider", ephemeral: ephemeralB)
        }
        try rejects { _ = try LobbyRequest(request.message, offer: direct) }
        let directRequest = try LobbyRequest.create(offer: direct, identity: signingB, name: "Bob", ephemeral: ephemeralB)
        let directCaller = try LobbyExchange(offer: direct, request: directRequest, ephemeral: ephemeralA, caller: true)
        let directJoiner = try LobbyExchange(offer: direct, request: directRequest, ephemeral: ephemeralB, caller: false)
        precondition(directCaller.code == directJoiner.code)
        try directCaller.verifyConfirmation(directJoiner.confirmation())
        var directPush = push
        directPush["offer"] = direct.message
        _ = try IncomingCallPush(directPush, scope: "wss://example.com/relay", recipient: receiver, now: 1000)
        let other = VoiceProtocol.base64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        directPush["recipient"] = other
        try rejects {
            _ = try IncomingCallPush(directPush, scope: "wss://example.com/relay", recipient: other, now: 1000)
        }
        let caller = try LobbyExchange(offer: offer, request: request, ephemeral: ephemeralA, caller: true)
        let joiner = try LobbyExchange(offer: offer, request: request, ephemeral: ephemeralB, caller: false)
        precondition(caller.code == joiner.code)
        try caller.verifyConfirmation(joiner.confirmation())
        let box = try caller.seal(invite)
        let received = try joiner.open(box)
        precondition(received.text == invite.text)
        var altered = try VoiceProtocol.decode(box, size: 98)
        altered[20] ^= 1
        try rejects { _ = try joiner.open(VoiceProtocol.base64(altered)) }
        try rejects { try caller.verifyConfirmation(VoiceProtocol.base64(Data(repeating: 0, count: 32))) }
        var wrongOffer = offer.message
        wrongOffer["name"] = "Impostor"
        try rejects { _ = try LobbyOffer(wrongOffer) }
        var wrongRequest = request.message
        wrongRequest["ephemeral"] = offer.ephemeral
        try rejects { _ = try LobbyRequest(wrongRequest, offer: offer) }
        let nextOffer = try LobbyOffer.create(identity: signingA, name: "Alice", ephemeral: ephemeralA)
        wrongRequest = request.message
        wrongRequest["call"] = nextOffer.id
        try rejects { _ = try LobbyRequest(wrongRequest, offer: nextOffer) }
        let nextRequest = try LobbyRequest.create(
            offer: offer, identity: signingB, name: "Bob", ephemeral: ephemeralB
        )
        let nextExchange = try LobbyExchange(offer: offer, request: nextRequest, ephemeral: ephemeralB, caller: false)
        precondition(nextExchange.code != joiner.code)
        try rejects { _ = try nextExchange.open(box) }
        try rejects {
            _ = try LobbyExchange(offer: offer, request: request,
                                  ephemeral: Curve25519.KeyAgreement.PrivateKey(), caller: true)
        }
        print("PASS: audio and lobby signatures, binding, encryption, confirmation, limits and URL policy")
    }
}
