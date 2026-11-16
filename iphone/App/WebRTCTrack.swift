import WebRTC

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
        return transceiver
    }
}
