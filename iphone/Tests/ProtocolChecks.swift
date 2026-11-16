import CryptoKit
import Foundation

@main
struct ProtocolChecks {
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "Expected rejection", code: 1)
    }

    static func webRTCSetupChecks() {
        let cases: [(Bool, Bool, Bool, Bool, Bool, Bool, WebRTCSetupStage)] = [
            (false, false, false, false, false, false, .waitingForOffer),
            (false, false, false, true, false, false, .applyingRemote),
            (true, false, false, false, false, false, .creatingLocal),
            (true, true, false, false, false, false, .gathering),
            (true, true, false, false, false, true, .sending),
            (true, true, true, false, false, true, .waitingForAnswer),
            (true, true, true, true, true, true, .connectivity),
            (false, true, true, true, true, true, .connectivity)
        ]
        let sdp = "a=ice-pwd:secret-value\r\n"
            + "a=candidate:1 1 udp 123 192.0.2.10 1234 typ host\r\n"
            + "a=candidate:2 1 udp 123 192.0.2.11 1235 typ srflx\r\n"
            + "a=candidate:3 1 udp 123 192.0.2.12 1236 typ relay\r\n"
            + "a=candidate:4 1 udp 123 192.0.2.13 1237 typ\r\n"
        precondition(WebRTCSetupProgress.candidateSummary(sdp) == "host=1, srflx=1, relay=1")
        precondition(WebRTCSetupProgress.candidateSummary(nil) == "host=0, srflx=0, relay=0")
        for item in cases {
            let progress = WebRTCSetupProgress(
                isOfferer: item.0, localReady: item.1, localDelivered: item.2,
                remoteReceived: item.3, remoteApplied: item.4, gatheringComplete: item.5)
            precondition(progress.stage == item.6)
            let failure = progress.failure(localSDP: sdp, remoteSDP: nil)
            precondition(failure.contains("[\(item.6.rawValue)]"))
            precondition(!failure.contains("192.0.2.") && !failure.contains("secret-value"))
        }
    }

    static func webRTCQualityChecks() throws {
        func stats(_ scale: Double, transport: String = "tcp") -> [String: WebRTCStat] {
            [
                "in": WebRTCStat(type: "inbound-rtp", numbers: [
                    "packetsReceived": 450 * scale, "packetsLost": 50 * scale, "bytesReceived": 50_000 * scale,
                    "concealedSamples": 4_800 * scale, "totalSamplesReceived": 480_000 * scale,
                    "jitterBufferDelay": 40 * scale, "jitterBufferEmittedCount": 480_000 * scale,
                    "totalAudioEnergy": 0.01 * scale, "totalSamplesDuration": 10 * scale, "jitter": 0.012
                ], strings: ["kind": "audio"]),
                "out": WebRTCStat(type: "outbound-rtp", numbers: ["packetsSent": 500 * scale, "bytesSent": 60_000 * scale],
                                  strings: ["kind": "audio"]),
                "rin": WebRTCStat(type: "remote-inbound-rtp", numbers: ["fractionLost": 0.02, "roundTripTime": 0.3],
                                  strings: ["kind": "audio"]),
                "mic": WebRTCStat(type: "media-source", numbers: ["totalAudioEnergy": 0, "totalSamplesDuration": 10 * scale],
                                  strings: ["kind": "audio"]),
                "t": WebRTCStat(type: "transport", strings: ["selectedCandidatePairId": "p"]),
                "p": WebRTCStat(type: "candidate-pair", numbers: ["currentRoundTripTime": 0.25, "nominated": 1],
                                strings: ["localCandidateId": "l", "remoteCandidateId": "r", "state": "succeeded"]),
                "l": WebRTCStat(type: "local-candidate", strings: [
                    "candidateType": "relay", "protocol": "udp", "relayProtocol": transport, "address": "192.0.2.1"]),
                "r": WebRTCStat(type: "remote-candidate", strings: [
                    "candidateType": "srflx", "protocol": "udp", "address": "198.51.100.2"])
            ]
        }
        let first = WebRTCQualitySample(stats(1), seconds: 100)
        let second = WebRTCQualitySample(stats(2), seconds: 110)
        precondition(first.route == "relay/tcp>srflx/udp" && first.roundTrip == 0.25)
        precondition(WebRTCQualitySample(stats(1, transport: "10.0.0.1"), seconds: 0).route == "relay>srflx/udp")
        guard let link = WebRTCQualityLink(peer: "peer", from: first, to: second, muted: false) else {
            preconditionFailure("interval")
        }
        precondition(link.secs == 10 && link.rttMs == 250 && link.jitterMs == 12)
        precondition(link.lossIn == 10 && link.lossOut == 2 && link.conceal == 1)
        precondition(link.rxPps == 45 && link.txPps == 50 && link.rxKbps == 40 && link.txKbps == 48)
        precondition(link.jbMs == 0.1 && link.spkDb == -30 && link.micDb == -127)
        precondition(WebRTCQualityLink(peer: "peer", from: second, to: first, muted: false) == nil)
        let message = try WebRTCQualityLink.message(call: "call", links: [link])
        precondition(Set(message.keys) == ["type", "call", "links"] && message["type"] == "rtc-quality")
        let links = message["links"]!
        precondition(links.contains("\"rtt_ms\":250") && links.contains("\"route\":\"relay/tcp>srflx/udp\""))
        precondition(!links.contains("192.0.2.") && !links.contains("198.51.100."))
        try rejects { _ = try WebRTCQualityLink.message(call: "call", links: []) }
    }

    static func main() throws {
        webRTCSetupChecks()
        try webRTCQualityChecks()
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
