import AVFoundation
import Foundation
@preconcurrency import WebRTC

/// Audio-only mesh. The owner supplies only verified, roster-bound signaling.
/// WebRTC owns capture, Opus, jitter buffering, mixing, echo control and SRTP.
@MainActor
final class WebRTCAudio: NSObject, RTCPeerConnectionDelegate {
    private final class Link {
        let peer: String
        let connection: RTCPeerConnection
        var negotiation: Task<Void, Never>?
        var publishing: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var gatherCutoff: Task<Void, Never>?
        var gatherCutoffPassed = false
        var relayGathered = false
        var localSent = false
        var localDelivered = false
        var remoteSet = false
        var remoteApplied = false
        var quality: WebRTCQualitySample?
        init(peer: String, connection: RTCPeerConnection) {
            self.peer = peer
            self.connection = connection
        }
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCSetMinDebugLogLevel(.none)
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    private var session: WebRTCSession?
    private var links: [String: Link] = [:]
    private var track: RTCAudioTrack?
    private var stopped = false
    var send: ((String, String, String, String) async throws -> Void)?
    var onFailure: ((String) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var onProgress: ((String) -> Void)?
    /// Redacted per-link interval statistics, emitted every `WebRTCQualityLink.interval` seconds.
    var onQuality: (([WebRTCQualityLink]) -> Void)?
    private var sampler: Task<Void, Never>?

    static func prepare() {
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    static func configureAudio() throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        audio.ignoresPreferredAttributeConfigurationErrors = true
        try audio.setConfiguration(RTCAudioSessionConfiguration.webRTC())
    }

    static func activate(_ session: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(session)
    }

    static func deactivate(_ session: AVAudioSession) {
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false
        audio.audioSessionDidDeactivate(session)
    }

    func start(_ session: WebRTCSession) throws {
        guard !stopped, RTCAudioSession.sharedInstance().isActive,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw VoiceError.microphone
        }
        track = Self.factory.audioTrack(withTrackId: "canddle-audio")
        try update(session)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: WebRTCQualityLink.interval * 1_000_000_000) }
                catch { return }
                guard let self, !self.stopped else { return }
                await self.sampleQuality()
            }
        }
    }

    private static func sample(_ connection: RTCPeerConnection) async -> WebRTCQualitySample {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                var stats: [String: WebRTCStat] = [:]
                for (id, entry) in report.statistics {
                    var stat = WebRTCStat(type: entry.type)
                    for (key, value) in entry.values {
                        if let number = value as? NSNumber { stat.numbers[key] = number.doubleValue }
                        else if let text = value as? String, text.utf8.count <= 128 { stat.strings[key] = text }
                    }
                    stats[id] = stat
                }
                continuation.resume(returning: WebRTCQualitySample(stats, seconds: report.timestamp_us / 1_000_000))
            }
        }
    }

    private func sampleQuality() async {
        var reports: [WebRTCQualityLink] = []
        let muted = !(track?.isEnabled ?? false)
        for link in links.values.sorted(by: { $0.peer < $1.peer }) where link.connection.connectionState == .connected {
            let next = await Self.sample(link.connection)
            guard current(link) else { continue }
            if let previous = link.quality,
               let report = WebRTCQualityLink(peer: link.peer, from: previous, to: next, muted: muted) {
                reports.append(report)
            }
            link.quality = next
        }
        if !stopped, !reports.isEmpty { onQuality?(Array(reports.prefix(5))) }
    }

    func update(_ next: WebRTCSession) throws {
        guard !stopped, let track, !next.servers.isEmpty,
              next.roster.members.contains(where: { $0.id == next.identity }) else {
            throw VoiceError.peer
        }
        if session?.roster.message == next.roster.message { return }
        // New certificates and ICE credentials on every signed membership epoch.
        // Closing old links also revokes media access for removed participants.
        closeLinks()
        session = next
        onConnected?(false)
        for member in next.roster.members where member.id != next.identity {
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.bundlePolicy = .maxBundle
            config.rtcpMuxPolicy = .require
            config.continualGatheringPolicy = .gatherOnce
            config.iceServers = next.servers.map {
                RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
            }
            guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                throw VoiceError.packet
            }
            guard let transceiver = pc.addTransceiver(with: track) else {
                pc.close(); throw VoiceError.packet
            }
            let opus = Self.factory.rtpSenderCapabilities(forKind: "audio").codecs.filter {
                $0.name.lowercased() == "opus"
            }
            guard !opus.isEmpty else { pc.close(); throw VoiceError.packet }
            do { try transceiver.setCodecPreferences(opus, error: ()) }
            catch { pc.close(); throw error }
            let link = Link(peer: member.id, connection: pc)
            links[member.id] = link
            setDeadline(link, seconds: 25)
            if next.identity < member.id {
                link.negotiation = Task {
                    do {
                        let offer = try await pc.offer(for: constraints)
                        guard current(link) else { return }
                        try await pc.setLocalDescription(offer)
                        if current(link) { localDescriptionSet(link) }
                    } catch { if current(link) { fail("WebRTC offer could not be created.") } }
                }
            }
        }
        if links.isEmpty { onConnected?(true) }
        reportProgress()
    }

    func receive(_ signal: WebRTCSignal) {
        guard let session, signal.message["epoch"] == session.roster.message["epoch"],
              let link = links[signal.identity], !link.remoteSet, current(link) else { return }
        link.remoteSet = true
        reportProgress()
        link.negotiation = Task {
            do {
                let description = RTCSessionDescription(type: signal.kind == "offer" ? .offer : .answer,
                                                        sdp: signal.sdp)
                try await link.connection.setRemoteDescription(description)
                guard current(link) else { return }
                link.remoteApplied = true
                reportProgress()
                if signal.kind == "offer" {
                    let answer = try await link.connection.answer(for: constraints)
                    guard current(link) else { return }
                    try await link.connection.setLocalDescription(answer)
                    if current(link) { localDescriptionSet(link) }
                }
            } catch { if current(link) { fail("Authenticated WebRTC negotiation failed.") } }
        }
    }

    /// Seconds to wait for full ICE gathering before sending the candidates found so far.
    /// libwebrtc can leave gathering incomplete indefinitely when one TURN transport or
    /// network interface is silent, even though usable candidates already exist.
    static let gatherCutoffSeconds: UInt64 = 4

    private func localDescriptionSet(_ link: Link) {
        link.gatherCutoff?.cancel()
        link.gatherCutoff = Task {
            do {
                try await Task.sleep(nanoseconds: Self.gatherCutoffSeconds * 1_000_000_000)
                guard current(link) else { return }
                link.gatherCutoffPassed = true
                publish(link)
            } catch {}
        }
        publish(link)
    }

    private func gatheringReady(_ link: Link) -> Bool {
        if link.connection.iceGatheringState == .complete { return true }
        // Non-trickle: once a TURN relay candidate exists (or the cutoff passes with at
        // least one candidate), later candidates would add little and may never arrive.
        let hasCandidate = link.connection.localDescription?.sdp.contains("a=candidate:") == true
        return hasCandidate && (link.relayGathered || link.gatherCutoffPassed)
    }

    private func publish(_ link: Link) {
        reportProgress()
        guard current(link), !link.localSent, let session,
              gatheringReady(link),
              let description = link.connection.localDescription else { return }
        link.localSent = true
        link.gatherCutoff?.cancel(); link.gatherCutoff = nil
        let epoch = session.roster.message["epoch"]!
        // Non-trickle ICE sends one bounded, signed description per directed
        // pair/epoch, including all candidates, instead of unsigned candidate updates.
        link.publishing = Task {
            do {
                guard let send else { throw VoiceError.ended }
                try await send(description.sdp, description.type == .offer ? "offer" : "answer", link.peer, epoch)
                guard current(link) else { return }
                link.localDelivered = true
                reportProgress()
            } catch { if current(link) { fail("WebRTC signaling could not be sent.") } }
        }
    }

    private func current(_ link: Link) -> Bool { !stopped && links[link.peer] === link }

    private func progress(_ link: Link) -> WebRTCSetupProgress {
        WebRTCSetupProgress(
            isOfferer: (session?.identity ?? "") < link.peer,
            localReady: link.connection.localDescription != nil,
            localDelivered: link.localDelivered,
            remoteReceived: link.remoteSet,
            remoteApplied: link.remoteApplied,
            gatheringComplete: link.localSent || link.connection.iceGatheringState == .complete)
    }

    private func reportProgress() {
        guard !stopped, let link = links.values.sorted(by: { $0.peer < $1.peer }).first(where: {
            $0.connection.connectionState != .connected
        }) else { return }
        onProgress?("Connecting WebRTC audio: \(progress(link).stage.status)")
    }

    private func failConnection(_ link: Link) {
        fail(progress(link).failure(localSDP: link.connection.localDescription?.sdp,
                                    remoteSDP: link.connection.remoteDescription?.sdp))
    }

    private func setDeadline(_ link: Link, seconds: UInt64) {
        link.deadline?.cancel()
        link.deadline = Task {
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if current(link) {
                    failConnection(link)
                }
            } catch {}
        }
    }

    private func changed(_ pc: RTCPeerConnection, state: RTCPeerConnectionState) {
        guard let link = links.values.first(where: { $0.connection === pc }), current(link) else { return }
        switch state {
        case .connected:
            link.deadline?.cancel(); link.deadline = nil
        case .disconnected:
            if link.deadline == nil { setDeadline(link, seconds: 10) }
        case .failed:
            failConnection(link)
        default: break
        }
        onConnected?(!links.isEmpty && links.values.allSatisfy { $0.connection.connectionState == .connected })
        reportProgress()
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stop()
        onFailure?(message)
    }

    func mute(_ muted: Bool) { track?.isEnabled = !muted }

    private func closeLinks() {
        let old = Array(links.values)
        links = [:]
        for link in old {
            link.negotiation?.cancel()
            link.publishing?.cancel()
            link.deadline?.cancel()
            link.gatherCutoff?.cancel()
            link.connection.close()
        }
    }

    func stop() {
        stopped = true
        sampler?.cancel(); sampler = nil
        track?.isEnabled = false
        closeLinks()
        track = nil
        session = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in
            if let link = self.links.values.first(where: { $0.connection === peerConnection }) {
                self.publish(link)
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.changed(peerConnection, state: newState) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.contains(" typ relay") else { return }
        Task { @MainActor in
            // Let the description pick up the new candidate before publishing it.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let link = self.links.values.first(where: { $0.connection === peerConnection }) {
                link.relayGathered = true
                self.publish(link)
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close()
    }
}
