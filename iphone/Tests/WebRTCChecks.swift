import CryptoKit
import Darwin
import Foundation
import WebRTC

/// A test-only forwarding path, delaying opaque UDP datagrams 80 ms each way.
private final class DelayedAudioPath: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32
    private let queue = DispatchQueue(label: "canddle.test.delayed-path")
    private let source: DispatchSourceRead
    private var running = true
    private let endpoints: [sockaddr_in]

    init(addresses: [(String, UInt16)]) throws {
        func endpoint(_ host: String, _ port: UInt16) -> sockaddr_in {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            value.sin_addr.s_addr = inet_addr(host)
            value.sin_port = port.bigEndian
            return value
        }
        endpoints = addresses.map { endpoint($0.0, $0.1) }
        socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw VoiceError.packet }
        let fd = socketFD
        var address = endpoint(addresses[0].0, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw VoiceError.packet }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw VoiceError.packet
        }
        port = UInt16(bigEndian: address.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.read() }
        source.resume()
    }

    func stop() { queue.sync { running = false; source.cancel() } }

    private func read() {
        while running {
            var data = [UInt8](repeating: 0, count: 65_536)
            var from = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &data, data.count, 0, $0, &size)
                }
            }
            guard count > 0 else { return }
            guard let index = endpoints.firstIndex(where: {
                $0.sin_addr.s_addr == from.sin_addr.s_addr && $0.sin_port == from.sin_port
            }) else { continue }
            let payload = Data(data.prefix(count))
            let destination = endpoints[1 - index]
            queue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                guard let self, self.running else { return }
                var target = destination
                _ = payload.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(self.socketFD, bytes.baseAddress, bytes.count, 0, $0,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}

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

    /// Regression: the answering phone negotiated recvonly and sent no audio.
    /// Only SDP is created. Neither side applies the answer, so no send stream
    /// starts and the microphone is never opened.
    @MainActor static func answererSends(factory: RTCPeerConnectionFactory, config: RTCConfiguration,
                                         constraints: RTCMediaConstraints) async throws {
        let opus = factory.rtpSenderCapabilities(forKind: "audio").codecs.filter { $0.name.lowercased() == "opus" }
        func answer(legacyAnswerer: Bool) async throws -> (sdp: String, transceivers: Int) {
            let a = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
            let b = factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
            defer { a.close(); b.close() }
            _ = try a.attachAudio(factory.audioTrack(withTrackId: "offerer"), codecs: opus)
            let track = factory.audioTrack(withTrackId: "answerer")
            if legacyAnswerer {
                // The pre-fix app path.
                try b.addTransceiver(with: track)!.setCodecPreferences(opus, error: ())
            } else {
                let transceiver = try b.attachAudio(track, codecs: opus)
                precondition(transceiver.sender.parameters.encodings.allSatisfy {
                    $0.maxBitrateBps?.intValue == 32_000 && !$0.adaptiveAudioPacketTime
                        && $0.networkPriority == .high
                })
                precondition(transceiver.sender.setAudioBitrateCeiling(16_000))
                precondition(transceiver.sender.setAudioBitrateCeiling(32_000))
            }
            // The SDK must accept the 10 ms request and keep it when it
            // re-serializes the local description (that text is what gets signed).
            let offer = WebRTCMediaTuning.shortPackets(try await a.offer(for: constraints))
            try await a.setLocalDescription(offer)
            let signed = a.localDescription?.sdp ?? ""
            precondition(signed.contains(WebRTCPacketTime.attribute), "SDK dropped a=ptime from the local offer")
            try WebRTCSignal.validateSDP(signed)
            try await b.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: signed))
            let answer = WebRTCMediaTuning.shortPackets(try await b.answer(for: constraints))
            precondition(answer.sdp.contains(WebRTCPacketTime.attribute))
            return (answer.sdp, b.transceivers.count)
        }
        func direction(_ sdp: String) -> String? {
            sdp.components(separatedBy: .newlines).first {
                ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains($0.trimmingCharacters(in: .whitespaces))
            }?.trimmingCharacters(in: .whitespaces)
        }
        let fixed = try await answer(legacyAnswerer: false)
        precondition(direction(fixed.sdp) == "a=sendrecv", "answerer must send: \(direction(fixed.sdp) ?? "none")")
        precondition(fixed.transceivers == 1, "offer must bind to the answerer's own track")
        precondition(fixed.sdp.contains("opus/48000/2"))
        // Shows this check catches the bug: with addTransceiver the answer is recvonly.
        let legacy = try await answer(legacyAnswerer: true)
        precondition(direction(legacy.sdp) == "a=recvonly" && legacy.transceivers == 2,
                     "SDK no longer reproduces the addTransceiver answerer bug; review this check")
        print("PASS answerer-sends: addTrack answer is sendrecv; addTransceiver answer was recvonly")
    }

    @MainActor static func main() async throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        let discovery = RTCConfiguration()
        WebRTCMediaTuning.configure(discovery, servers: [CallICEServer(
            urls: ["turn:turn.example:3478?transport=udp", "turn:turn.example:3478?transport=tcp"],
            username: "test", credential: "test")], trickle: true)
        precondition(discovery.iceServers.count == 2)
        precondition(discovery.iceServers.last?.urlStrings == ["stun:turn.example:3478"])
        precondition(discovery.continualGatheringPolicy == .gatherContinually)
        let upgrade = CommandLine.arguments.contains("--route-upgrade")
        let trickle = CommandLine.arguments.contains("--trickle")
            || CommandLine.arguments.contains("--trickle-stalled-turn") || upgrade
        let stalledTURN = CommandLine.arguments.contains("--stalled-turn")
            || CommandLine.arguments.contains("--trickle-stalled-turn")
        WebRTCMediaTuning.configure(config, servers: [], trickle: trickle)
        precondition(config.audioJitterBufferFastAccelerate && config.audioJitterBufferMaxPackets == 60)
        precondition(config.iceBackupCandidatePairPingInterval == 5_000 && config.rtcpAudioReportIntervalMs == 1_000)
        precondition(config.iceTransportPolicy == .all && config.candidateNetworkPolicy == .all)
        precondition(config.continualGatheringPolicy == (trickle ? .gatherContinually : .gatherOnce))
        if CommandLine.arguments.contains("--answerer-sends") {
            try await answererSends(factory: factory, config: config, constraints: constraints)
            return
        }
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
        if upgrade {
            try await upgradeRoute(connections: [a, b], descriptions: [signedOffer, signedAnswer],
                                   sessions: sessions, keys: keys)
            return
        }
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

    @MainActor static func upgradeRoute(connections: [RTCPeerConnection], descriptions: [WebRTCSignal],
                                       sessions: [WebRTCSession], keys: [Curve25519.Signing.PrivateKey]) async throws {
        func direct(_ connection: RTCPeerConnection) -> String? {
            connection.localDescription?.sdp.components(separatedBy: .newlines).first {
                let fields = $0.split(separator: " ")
                return fields.count >= 8 && $0.hasPrefix("a=candidate:") && fields[2] == "udp"
                    && fields[7] == "host" && !fields[4].contains(":")
            }.map { String($0.dropFirst(2)) }
        }
        try await wait { connections.allSatisfy { direct($0) != nil } }
        let candidates = connections.map { direct($0)! }
        let addresses = candidates.map { candidate -> (String, UInt16) in
            let fields = candidate.split(separator: " ")
            return (String(fields[4]), UInt16(fields[5])!)
        }
        precondition(addresses[0].0 == addresses[1].0)
        let path = try DelayedAudioPath(addresses: addresses)
        defer { path.stop() }
        var streams = [WebRTCCandidateStream(), WebRTCCandidateStream()]
        func deliver(_ raw: String, index: Int) async throws {
            let description = descriptions[index]
            let signed = try WebRTCCandidate.create(candidate: raw, mid: description.mid!,
                sequence: streams[index].sequence + 1, session: sessions[index],
                description: description, signing: keys[index])
            let verified = try WebRTCCandidate(signed.message, session: sessions[1 - index],
                                               description: description)
            try streams[index].accept(verified)
            try await connections[1 - index].add(RTCIceCandidate(
                sdp: verified.candidate, sdpMLineIndex: 0, sdpMid: verified.mid))
        }
        for index in 0..<2 {
            try await deliver("candidate:forward\(index) 1 udp 1 \(addresses[0].0) \(path.port) typ relay",
                              index: index)
        }
        try await wait { connections.allSatisfy { $0.connectionState == .connected } }
        func selected(_ connection: RTCPeerConnection) async -> (port: Int, rtt: Double) {
            let stats = await connection.statistics().statistics
            let pairID = stats.values.first { $0.type == "transport" }!.values["selectedCandidatePairId"] as! String
            let pair = stats[pairID]!
            let remoteID = pair.values["remoteCandidateId"] as! String
            return ((stats[remoteID]!.values["port"] as! NSNumber).intValue,
                    (pair.values["currentRoundTripTime"] as! NSNumber).doubleValue)
        }
        let before = await selected(connections[0])
        precondition(before.port == Int(path.port) && before.rtt >= 0.1)
        for index in 0..<2 { try await deliver(candidates[index], index: index) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var after = before
        while ContinuousClock.now < deadline {
            precondition(connections.allSatisfy { $0.connectionState == .connected })
            after = await selected(connections[0])
            let other = await selected(connections[1])
            if after.port != Int(path.port), other.port != Int(path.port),
               after.rtt < before.rtt / 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let otherAfter = await selected(connections[1])
        precondition(after.port != Int(path.port) && otherAfter.port != Int(path.port)
                     && after.rtt < before.rtt / 2,
                     "ICE must upgrade from the delayed forwarding path to direct UDP")
        print("PASS route-upgrade: signed direct UDP replaces forwarding path while connected; "
              + "RTT \(Int(before.rtt * 1000)) -> \(Int(after.rtt * 1000)) ms; no microphone")
    }
}
