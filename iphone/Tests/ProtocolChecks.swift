import CryptoKit
import Foundation

@main
struct ProtocolChecks {
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "Expected rejection", code: 1)
    }

    static func trickleChecks() throws {
        let keys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()].sorted {
            VoiceProtocol.base64($0.publicKey.rawRepresentation) < VoiceProtocol.base64($1.publicKey.rawRepresentation)
        }
        let offer = try LobbyOffer.create(identity: keys[0], name: "Caller", ephemeral: .init(), webRTC: true)
        let request = try LobbyRequest.create(offer: offer, identity: keys[1], name: "Recipient", ephemeral: .init())
        let members = [GroupMember(message: offer.message), GroupMember(message: request.message)]
        let roster = try GroupRoster.create(offer: offer, revision: 1, members: members, signing: keys[0])
        let sessions = keys.map {
            WebRTCSession(offer: offer, roster: roster, identity: VoiceProtocol.base64($0.publicKey.rawRepresentation),
                          servers: [], trickle: true)
        }
        let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtcp-mux\r\na=mid:0\r\n"
            + "a=rtpmap:111 opus/48000/2\r\na=fingerprint:sha-256 "
            + Array(repeating: "AB", count: 32).joined(separator: ":") + "\r\n"
            + WebRTCSignal.trickleAttribute + "\r\n"
        let signal = try WebRTCSignal.create(sdp: sdp, kind: "offer", to: sessions[1].identity,
                                            session: sessions[0], signing: keys[0])
        let raw = "candidate:123 1 udp 2122260223 192.0.2.10 54321 typ host"
        let update = try WebRTCCandidate.create(candidate: raw, mid: "0", sequence: 1, session: sessions[0],
                                               description: signal, signing: keys[0])
        let verified = try WebRTCCandidate(update.message, session: sessions[1], description: signal)
        precondition(verified.candidate == raw && signal.supportsTrickle && signal.mid == "0")
        // 10 ms packet request: placed inside the audio section, replaces any
        // existing ptime, preserves CRLF, and still validates and signs.
        let short = WebRTCPacketTime.request(sdp.replacingOccurrences(of: "a=rtcp-mux\r\n",
                                                                       with: "a=rtcp-mux\r\na=ptime:20\r\n"))
        let shortLines = short.components(separatedBy: "\r\n")
        precondition(shortLines.filter { $0.hasPrefix("a=ptime:") } == ["a=ptime:10"])
        precondition(shortLines.firstIndex(of: "a=ptime:10")! == shortLines.firstIndex(of: "a=rtpmap:111 opus/48000/2")! + 1)
        precondition(!short.replacingOccurrences(of: "\r\n", with: "").contains("\n") && short.hasSuffix("\r\n"))
        precondition(WebRTCPacketTime.request(short) == short)
        try WebRTCSignal.validateSDP(short)
        _ = try WebRTCSignal.create(sdp: short, kind: "answer", to: sessions[0].identity,
                                    session: sessions[1], signing: keys[1])
        precondition(WebRTCPacketTime.request("v=0\r\n") == "v=0\r\n")
        for field in update.message.keys {
            var tampered = update.message
            tampered[field] = field == "candidate" ? raw.replacingOccurrences(of: "54321", with: "54322") : "invalid"
            try rejects { _ = try WebRTCCandidate(tampered, session: sessions[1], description: signal) }
        }
        for raw in [raw + "\r\na=ice-pwd:bad", String(repeating: "a", count: 2049),
                    "m=audio 9 UDP/TLS/RTP/SAVPF 111", raw.replacingOccurrences(of: " 1 udp ", with: " 2 udp ")] {
            try rejects {
                _ = try WebRTCCandidate.create(candidate: raw, mid: "0", sequence: 1, session: sessions[0],
                                              description: signal, signing: keys[0])
            }
        }
        let changed = try WebRTCSignal.create(sdp: sdp + "a=x-test:changed\r\n", kind: "offer",
                                              to: sessions[1].identity, session: sessions[0], signing: keys[0])
        try rejects { _ = try WebRTCCandidate(update.message, session: sessions[1], description: changed) }
        var oldRelay = sessions[1]
        oldRelay.trickle = false
        try rejects { _ = try WebRTCCandidate(update.message, session: oldRelay, description: signal) }
        let nextRoster = try GroupRoster.create(offer: offer, revision: 2, members: members, signing: keys[0])
        let next = WebRTCSession(offer: offer, roster: nextRoster, identity: sessions[1].identity,
                                servers: [], trickle: true)
        try rejects { _ = try WebRTCCandidate(update.message, session: next, description: signal) }
        var stream = WebRTCCandidateStream()
        try stream.accept(verified)
        try rejects { try stream.accept(verified) }
        let end = try WebRTCCandidate.create(candidate: "", mid: "0", sequence: 2, session: sessions[0],
                                            description: signal, signing: keys[0])
        try stream.accept(end)
        precondition(stream.ended)
        try rejects { try stream.accept(end) }
        stream = WebRTCCandidateStream()
        for sequence in 1...WebRTCCandidate.limit {
            try stream.accept(WebRTCCandidate.create(candidate: raw, mid: "0", sequence: sequence,
                session: sessions[0], description: signal, signing: keys[0]))
        }
        try rejects {
            _ = try WebRTCCandidate.create(candidate: raw, mid: "0", sequence: 65, session: sessions[0],
                                          description: signal, signing: keys[0])
        }
        try stream.accept(WebRTCCandidate.create(candidate: "", mid: "0", sequence: 65, session: sessions[0],
                                               description: signal, signing: keys[0]))
    }

    static func webRTCSetupChecks() {
        var recovery = WebRTCConnectionRecovery()
        precondition(!recovery.hasConnected)
        precondition(!recovery.request(supported: false) && recovery.attempts == 0)
        // Initial ICE failure must be retryable without ever reaching connected.
        precondition(recovery.request(supported: true) && recovery.attempts == 1)
        precondition(recovery.request(supported: true) && recovery.attempts == 2)
        precondition(!recovery.request(supported: true) && !recovery.hasConnected)
        recovery.connected()
        precondition(recovery.hasConnected && recovery.attempts == 0)
        precondition(recovery.request(supported: true))
        precondition(recovery.request(supported: true))
        precondition(!recovery.request(supported: true))
        precondition(WebRTCConnectionRecovery.setupSeconds == 90)
        precondition(WebRTCConnectionRecovery.attemptSeconds == 25)
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
                    "candidateType": "srflx", "protocol": "udp", "address": "198.51.100.2"]),
                // A direct IPv6 host pair whose checks failed, e.g. a blocking firewall.
                "lh": WebRTCStat(type: "local-candidate", strings: [
                    "candidateType": "host", "protocol": "udp", "address": "2001:db8::1"]),
                "rh": WebRTCStat(type: "remote-candidate", strings: [
                    "candidateType": "host", "protocol": "udp", "address": "2001:db8::2"]),
                "p2": WebRTCStat(type: "candidate-pair", strings: [
                    "localCandidateId": "lh", "remoteCandidateId": "rh", "state": "failed"]),
                "p3": WebRTCStat(type: "candidate-pair", strings: [
                    "localCandidateId": "lh", "remoteCandidateId": "r", "state": "in-progress"])
            ]
        }
        let first = WebRTCQualitySample(stats(1), seconds: 100)
        let second = WebRTCQualitySample(stats(2), seconds: 110)
        precondition(first.selectedPair == "p")
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
        let path = first.path
        precondition(path.localHost == 1 && path.localSrflx == 0 && path.localRelay == 1 && path.localIPv6 == 1)
        precondition(path.remoteHost == 1 && path.remoteSrflx == 1 && path.remoteRelay == 0 && path.remoteIPv6 == 1)
        precondition(path.directSucceeded == 0 && path.directFailed == 1 && path.routeIPv6 == false)
        precondition(link.lHost == 1 && link.lRelay == 1 && link.lV6 == 1 && link.rSrflx == 1)
        precondition(link.dOk == 0 && link.dFail == 1 && link.v6 == 0 && link.lan == nil)
        precondition(link.relayed == true)
        for (route, relayed) in [("host/udp>srflx/udp", false as Bool?), ("prflx/udp>host/udp", false),
                                 ("srflx/udp>relay/udp", true), ("unknown>host/udp", nil), ("", nil)] {
            var probe = link
            probe.route = route
            precondition(probe.relayed == relayed)
        }
        let message = try WebRTCQualityLink.message(call: "call", links: [link])
        precondition(Set(message.keys) == ["type", "call", "links"] && message["type"] == "rtc-quality")
        let links = message["links"]!
        precondition(links.contains("\"rtt_ms\":250") && links.contains("\"route\":\"relay/tcp>srflx/udp\""))
        precondition(!links.contains("192.0.2.") && !links.contains("198.51.100."))
        precondition(links.contains("\"d_fail\":1") && links.contains("\"l_v6\":1") && links.contains("\"v6\":0"))
        precondition(!links.contains("2001:db8") && !links.contains("\"lan\""))
        var lan = link
        lan.lan = 0
        let lanMessage = try WebRTCQualityLink.message(call: "call", links: [lan])
        precondition(lanMessage["links"]!.contains("\"lan\":0"))
        let legacy = try WebRTCQualityLink.message(call: "call", links: [lan.withoutPath()])["links"]!
        for key in ["l_host", "r_srflx", "d_ok", "d_fail", "\"v6\"", "\"lan\""] {
            precondition(!legacy.contains(key), "old relays reject \(key)")
        }
        precondition(legacy.contains("\"rtt_ms\":250"))
        try rejects { _ = try WebRTCQualityLink.message(call: "call", links: []) }
        qualityIndicatorChecks(link)
        latencyPolicyChecks(link)
    }

    static func latencyPolicyChecks(_ report: WebRTCQualityLink) {
        for complete in [false, true] {
            precondition(!WebRTCCandidateStream.shouldEnd(continual: true, gatheringComplete: complete, discovered: 63))
            precondition(WebRTCCandidateStream.shouldEnd(continual: true, gatheringComplete: complete, discovered: 64))
        }
        precondition(WebRTCCandidateStream.shouldEnd(continual: false, gatheringComplete: true, discovered: 1))
        precondition(!WebRTCCandidateStream.shouldEnd(continual: false, gatheringComplete: false, discovered: 1))
        let turn = CallICEServer(urls: [
            "turn:voice.example:3478?transport=udp", "turn:voice.example:3478",
            "turn:voice.example:3478?transport=tcp", "turns:voice.example:5349?transport=tcp",
            "turn:[2001:db8::1]:3478?transport=udp"
        ], username: "test", credential: "test")
        precondition(turn.stunURLs == ["stun:[2001:db8::1]:3478", "stun:voice.example:3478"])
        precondition(CallICEServer(urls: ["turn:voice.example:80?transport=tcp", "turns:voice.example:443"],
                                   username: "test", credential: "test").stunURLs.isEmpty)
        var link = report
        link.txPps = 50
        link.muted = false
        link.lossOut = 0
        link.rttMs = 100
        link.lossIn = 50
        link.jitterMs = 300
        var policy = WebRTCAudioBitratePolicy()
        for _ in 0..<4 { precondition(policy.observe(link) == 32_000) }
        link.lossOut = 8
        for expected in [32_000, 24_000, 24_000, 16_000, 16_000, 16_000] {
            precondition(policy.observe(link) == expected)
        }
        link.lossOut = 0
        for expected in [16_000, 16_000, 24_000, 24_000, 24_000, 32_000] {
            precondition(policy.observe(link) == expected)
        }
        link.rttMs = 220
        precondition(policy.observe(link) == 32_000)
        precondition(policy.observe(link) == 24_000)
        // The caller resets evidence on an actual selected-pair change, even
        // when both paths share the same redacted route label.
        policy.resetObservations()
        for _ in 0..<3 { _ = policy.observe(link) }
        precondition(policy.ceiling == 32_000)
        link.route = "host/udp>host/udp"
        link.rttMs = 400
        for _ in 0..<3 { precondition(policy.observe(link) == 32_000) }
        link.lossOut = nil
        link.rttMs = nil
        for _ in 0..<6 { precondition(policy.observe(link) == 32_000) }
        link.lossOut = 50
        link.muted = true
        for _ in 0..<4 { precondition(policy.observe(link) == 32_000) }
        link.muted = false
        link.txPps = 0
        for _ in 0..<4 { precondition(policy.observe(link) == 32_000) }
        link.txPps = 50
        precondition(policy.observe(link) == 32_000)
        policy.resetObservations()
        precondition(policy.observe(link) == 32_000)
        link.lossOut = .nan
        link.rttMs = .infinity
        precondition(policy.observe(link) == 32_000)
    }

    static func qualityIndicatorChecks(_ report: WebRTCQualityLink) {
        for (route, expected) in [
            ("relay/tcp>srflx/udp", "TCP"), ("relay/tls>relay/udp", "TCP"),
            ("host/udp>relay/tcp", "UDP"), ("srflx/udp>unknown", "UDP"),
            ("unknown>relay/udp", "?"), ("relay>host/udp", "?"),
            ("relay/sctp>host/udp", "?"), ("garbage/udp", "?"), ("", "?")
        ] {
            precondition(CallQualityIndicator.localTransport(route) == expected)
        }
        var good = report
        good.rttMs = 100
        good.jitterMs = 10
        good.lossIn = 0
        good.lossOut = 0
        good.conceal = 0
        good.jbMs = 50
        precondition(CallQuality.estimate(good) == .good)
        let thresholds: [(WritableKeyPath<WebRTCQualityLink, Double?>, Double, Double)] = [
            (\.rttMs, 300, 600), (\.jitterMs, 30, 60), (\.lossIn, 2, 5),
            (\.lossOut, 2, 5), (\.conceal, 5, 10), (\.jbMs, 150, 300)
        ]
        for (field, fair, poor) in thresholds {
            var changed = good
            changed[keyPath: field] = fair - 0.1
            precondition(CallQuality.estimate(changed) == .good)
            changed[keyPath: field] = fair
            precondition(CallQuality.estimate(changed) == .fair)
            changed[keyPath: field] = poor
            precondition(CallQuality.estimate(changed) == .poor)
        }
        for field in [\WebRTCQualityLink.rttMs, \.jitterMs, \.lossIn, \.conceal] {
            for value: Double? in [nil, .nan, .infinity, -1] {
                var missing = good
                missing[keyPath: field] = value
                precondition(CallQuality.estimate(missing) == .measuring)
                missing.lossOut = 10
                precondition(CallQuality.estimate(missing) == .poor)
            }
        }
        var silent = good
        silent.muted = true
        silent.micDb = -127
        silent.spkDb = -127
        silent.rxKbps = 0
        silent.txKbps = 0
        precondition(CallQuality.estimate(silent) == .good)
        let now = Date(timeIntervalSince1970: 100)
        let reading = CallQualityReading(link: good, received: now)
        precondition(reading.indicator(at: now).quality == .good)
        precondition(reading.indicator(at: now.addingTimeInterval(25)).transport == "TCP")
        precondition(reading.indicator(at: now.addingTimeInterval(26)).quality == .stale)
        precondition(reading.indicator(at: now.addingTimeInterval(26)).transport == "?")
        precondition(reading.indicator(at: now.addingTimeInterval(-1)).quality == .stale)
        let udp = CallQualityIndicator(transport: "UDP", quality: .good)
        let tcp = CallQualityIndicator(transport: "TCP", quality: .poor)
        let pending = CallQualityIndicator(transport: "?", quality: .measuring)
        precondition(CallQualityIndicator.summary([]).quality == .measuring)
        precondition(CallQualityIndicator.summary([udp, udp]) == udp)
        let mixed = CallQualityIndicator.summary([udp, tcp])
        precondition(mixed.transport == "TCP / UDP" && mixed.quality == .poor)
        let partial = CallQualityIndicator.summary([udp, tcp, pending])
        precondition(partial.quality == .poor && partial.partial && partial.transport.contains("?"))
        precondition(CallQualityIndicator.summary([udp, pending]).quality == .measuring)
        precondition(CallQualityIndicator.summary([udp, .init(transport: "?", quality: .connecting)]).quality == .connecting)
        precondition(CallQualityIndicator.summary([udp, .init(transport: "?", quality: .stale)]).quality == .stale)
    }

    static func main() throws {
        try trickleChecks()
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
