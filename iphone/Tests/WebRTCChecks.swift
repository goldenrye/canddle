import CryptoKit
import Darwin
import Foundation
import WebRTC

/// Real ICE/DTLS negotiation without microphone tracks or device permissions.
@main
struct WebRTCChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = []
        let trickle = CommandLine.arguments.contains("--trickle")
            || CommandLine.arguments.contains("--trickle-stalled-turn")
        let stalledTURN = CommandLine.arguments.contains("--stalled-turn")
            || CommandLine.arguments.contains("--trickle-stalled-turn")
        var blackhole: Int32 = -1
        defer { if blackhole >= 0 { Darwin.close(blackhole) } }
        if stalledTURN {
            // A loopback UDP socket that deliberately never answers TURN requests.
            // No external server or microphone is accessed by this probe.
            blackhole = socket(AF_INET, SOCK_DGRAM, 0)
            guard blackhole >= 0 else { throw VoiceError.packet }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(blackhole, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw VoiceError.packet }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(blackhole, $0, &size)
                }
            }
            guard named == 0 else { throw VoiceError.packet }
            config.iceServers = [RTCIceServer(
                urlStrings: ["turn:127.0.0.1:\(UInt16(bigEndian: address.sin_port))?transport=udp"],
                username: "test", credential: "test")]
        }
        let a = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        let b = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        defer { a.close(); b.close() }
        for connection in [a, b] {
            let setup = RTCRtpTransceiverInit()
            setup.direction = .recvOnly
            let transceiver = connection.addTransceiver(of: .audio, init: setup)!
            try transceiver.setCodecPreferences(
                factory.rtpSenderCapabilities(forKind: "audio").codecs.filter { $0.name.lowercased() == "opus" },
                error: ())
        }
        let keys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()].sorted {
            VoiceProtocol.base64($0.publicKey.rawRepresentation) < VoiceProtocol.base64($1.publicKey.rawRepresentation)
        }
        let announcement = try LobbyOffer.create(identity: keys[0], name: "Caller",
                                                ephemeral: .init(), webRTC: true)
        let request = try LobbyRequest.create(offer: announcement, identity: keys[1],
                                              name: "Recipient", ephemeral: .init())
        let roster = try GroupRoster.create(offer: announcement, revision: 1,
            members: [GroupMember(message: announcement.message), GroupMember(message: request.message)],
            signing: keys[0])
        let sessions = keys.map {
            WebRTCSession(offer: announcement, roster: roster,
                          identity: VoiceProtocol.base64($0.publicKey.rawRepresentation), servers: [],
                          trickle: trickle)
        }
        let offer = try await a.offer(for: constraints)
        try await a.setLocalDescription(offer)
        if stalledTURN && !trickle {
            let deadline = ContinuousClock.now.advanced(by: .seconds(26))
            while a.iceGatheringState != .complete && ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let candidates = a.localDescription!.sdp.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("a=candidate:") }
            let progress = WebRTCSetupProgress(
                isOfferer: true, localReady: true, localDelivered: false,
                remoteReceived: false, remoteApplied: false,
                gatheringComplete: a.iceGatheringState == .complete)
            precondition(progress.stage == .gathering)
            precondition(!candidates.isEmpty && !candidates.contains { $0.contains(" typ relay") })
            print("STALLED TURN: complete=\(a.iceGatheringState == .complete), "
                  + "candidates=\(candidates.count), relay=\(candidates.filter { $0.contains(" typ relay") }.count)")
            return
        }
        func initialSDP(_ sdp: String) -> String {
            guard trickle else { return sdp }
            return sdp.components(separatedBy: .newlines).filter {
                !$0.isEmpty && !$0.hasPrefix("a=candidate:") && $0 != "a=end-of-candidates"
            }.joined(separator: "\r\n") + "\r\n" + WebRTCSignal.trickleAttribute + "\r\n"
        }
        if !trickle { try await wait { a.iceGatheringState == .complete } }
        let signedOffer = try WebRTCSignal.create(sdp: initialSDP(a.localDescription!.sdp), kind: "offer",
            to: sessions[1].identity, session: sessions[0], signing: keys[0])
        let verifiedOffer = try WebRTCSignal(signedOffer.message, session: sessions[1])
        try await b.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: verifiedOffer.sdp))
        let answer = try await b.answer(for: constraints)
        try await b.setLocalDescription(answer)
        if !trickle { try await wait { b.iceGatheringState == .complete } }
        let signedAnswer = try WebRTCSignal.create(sdp: initialSDP(b.localDescription!.sdp), kind: "answer",
            to: sessions[0].identity, session: sessions[1], signing: keys[1])
        let verifiedAnswer = try WebRTCSignal(signedAnswer.message, session: sessions[0])
        try await a.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: verifiedAnswer.sdp))
        if trickle {
            precondition(!verifiedOffer.sdp.contains("a=candidate:") && !verifiedAnswer.sdp.contains("a=candidate:"))
            // Deliberately deliver UDP candidates later than the former four-second
            // cutoff. There must be no connection until the signed updates arrive.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            precondition(a.connectionState != .connected && b.connectionState != .connected)
            if stalledTURN { precondition(a.iceGatheringState != .complete) }
            for (index, from, to, description) in [(0, a, b, signedOffer), (1, b, a, signedAnswer)] {
                let candidates = from.localDescription!.sdp.components(separatedBy: .newlines).filter {
                    $0.hasPrefix("a=candidate:") && $0.contains(" udp ")
                }.map { String($0.dropFirst(2)) }
                precondition(!candidates.isEmpty)
                var stream = WebRTCCandidateStream()
                for (offset, candidate) in candidates.enumerated() {
                    let signed = try WebRTCCandidate.create(candidate: candidate, mid: description.mid!,
                        sequence: offset + 1, session: sessions[index], description: description, signing: keys[index])
                    let verified = try WebRTCCandidate(signed.message, session: sessions[1 - index],
                                                      description: description)
                    try stream.accept(verified)
                    try await to.add(RTCIceCandidate(sdp: verified.candidate, sdpMLineIndex: 0, sdpMid: verified.mid))
                }
                let end = try WebRTCCandidate.create(candidate: "", mid: description.mid!, sequence: candidates.count + 1,
                    session: sessions[index], description: description, signing: keys[index])
                try stream.accept(WebRTCCandidate(end.message, session: sessions[1 - index], description: description))
            }
        }
        try await wait { a.connectionState == .connected && b.connectionState == .connected }
        let report = await a.statistics()
        precondition(report.statistics.values.contains {
            $0.type == "transport" && $0.values["dtlsState"] as? String == "connected"
        })
        precondition(verifiedOffer.sdp.contains("opus/48000/2"))
        if trickle {
            let pairID = report.statistics.values.first { $0.type == "transport" }!.values["selectedCandidatePairId"] as! String
            let candidateID = report.statistics[pairID]!.values["localCandidateId"] as! String
            precondition(report.statistics[candidateID]!.values["protocol"] as? String == "udp")
            print("PASS trickle: delayed signed UDP candidates connect ICE/DTLS after five seconds; silent TURN=\(stalledTURN)")
        }
        print("PASS WebRTC: signed audio SDP, ICE and DTLS connected; no microphone capture")
    }
}
