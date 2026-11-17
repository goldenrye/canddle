import WebRTC

enum WebRTCMediaTuning {
    static func configure(_ config: RTCConfiguration, servers: [CallICEServer], trickle: Bool) {
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceTransportPolicy = .all
        config.candidateNetworkPolicy = .all
        config.continualGatheringPolicy = trickle ? .gatherContinually : .gatherOnce
        config.audioJitterBufferFastAccelerate = true
        config.audioJitterBufferMaxPackets = 30
        config.iceBackupCandidatePairPingInterval = 5_000
        config.rtcpAudioReportIntervalMs = 1_000
        config.shouldPruneTurnPorts = false
        config.iceServers = servers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let stun = Array(Set(servers.flatMap(\.stunURLs))).sorted()
        if !stun.isEmpty { config.iceServers.append(RTCIceServer(urlStrings: stun)) }
    }
}

extension RTCRtpSender {
    @discardableResult
    func setAudioBitrateCeiling(_ bitsPerSecond: Int) -> Bool {
        let updated = parameters
        guard !updated.encodings.isEmpty else { return false }
        for encoding in updated.encodings {
            encoding.maxBitrateBps = NSNumber(value: bitsPerSecond)
            // Avoid increasing packet batching delay to save bandwidth.
            encoding.adaptiveAudioPacketTime = false
        }
        parameters = updated
        return parameters.encodings.allSatisfy { $0.maxBitrateBps?.intValue == bitsPerSecond }
    }
}

extension RTCPeerConnection {
    /// Attaches the local microphone track so the link sends in both roles.
    ///
    /// This must use addTrack, not addTransceiver. When an answerer applies a
    /// remote offer, JSEP (RFC 8829 section 5.10) reuses only transceivers that
    /// addTrack created. One made by addTransceiver is skipped: the offer then
    /// gets a new receive-only transceiver, the answer is recvonly, and the
    /// answering phone never sends audio.
    func attachAudio(_ track: RTCAudioTrack, codecs: [RTCRtpCodecCapability]) throws -> RTCRtpTransceiver {
        guard !codecs.isEmpty,
              let sender = add(track, streamIds: ["canddle"]),
              let transceiver = transceivers.first(where: { $0.sender.senderId == sender.senderId }) else {
            throw VoiceError.packet
        }
        try transceiver.setCodecPreferences(codecs, error: ())
        sender.setAudioBitrateCeiling(32_000)
        return transceiver
    }
}
