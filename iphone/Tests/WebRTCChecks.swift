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
        let stalledTURN = CommandLine.arguments.contains("--stalled-turn")
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
                          identity: VoiceProtocol.base64($0.publicKey.rawRepresentation), servers: [])
        }
        let offer = try await a.offer(for: constraints)
        try await a.setLocalDescription(offer)
        if stalledTURN {
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
        try await wait { a.iceGatheringState == .complete }
        let signedOffer = try WebRTCSignal.create(sdp: a.localDescription!.sdp, kind: "offer",
            to: sessions[1].identity, session: sessions[0], signing: keys[0])
        let verifiedOffer = try WebRTCSignal(signedOffer.message, session: sessions[1])
        try await b.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: verifiedOffer.sdp))
        let answer = try await b.answer(for: constraints)
        try await b.setLocalDescription(answer)
        try await wait { b.iceGatheringState == .complete }
        let signedAnswer = try WebRTCSignal.create(sdp: b.localDescription!.sdp, kind: "answer",
            to: sessions[0].identity, session: sessions[1], signing: keys[1])
        let verifiedAnswer = try WebRTCSignal(signedAnswer.message, session: sessions[0])
        try await a.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: verifiedAnswer.sdp))
        try await wait { a.connectionState == .connected && b.connectionState == .connected }
        let report = await a.statistics()
        precondition(report.statistics.values.contains {
            $0.type == "transport" && $0.values["dtlsState"] as? String == "connected"
        })
        precondition(verifiedOffer.sdp.contains("opus/48000/2"))
        print("PASS WebRTC: signed audio SDP, ICE and DTLS connected; no microphone capture")
    }
}
