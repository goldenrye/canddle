import CryptoKit
import Foundation

struct CallICEServer: Codable {
    let urls: [String]
    let username: String
    let credential: String

    static func parse(_ message: [String: String]) throws -> [CallICEServer] {
        guard Set(message.keys) == ["type", "servers"], message["type"] == "rtc-config",
              let raw = message["servers"], raw.utf8.count <= 4096 else { throw VoiceError.packet }
        let servers = try JSONDecoder().decode([Self].self, from: Data(raw.utf8))
        guard (1...4).contains(servers.count) else { throw VoiceError.packet }
        for server in servers {
            guard (1...4).contains(server.urls.count),
                  (1...128).contains(server.username.utf8.count),
                  (1...128).contains(server.credential.utf8.count) else { throw VoiceError.packet }
            for url in server.urls {
                let pattern = #"^turns?:([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}(\?transport=(udp|tcp))?$"#
                guard url.utf8.count <= 256,
                      url.range(of: pattern, options: .regularExpression) != nil,
                      let portText = url.components(separatedBy: "?")[0].split(separator: ":").last,
                      let port = Int(portText), (1...65535).contains(port),
                      !(url.hasPrefix("turns:") && url.hasSuffix("?transport=udp")) else {
                    throw VoiceError.packet
                }
            }
        }
        return servers
    }
}

struct WebRTCSession {
    let offer: LobbyOffer
    let roster: GroupRoster
    let identity: String
    let servers: [CallICEServer]
    var trickle = false
}

enum WebRTCSetupStage: String {
    case waitingForOffer = "RTC_WAIT_OFFER"
    case applyingRemote = "RTC_REMOTE_SDP"
    case creatingLocal = "RTC_LOCAL_SDP"
    case gathering = "RTC_GATHERING"
    case sending = "RTC_SIGNAL_SEND"
    case waitingForAnswer = "RTC_WAIT_ANSWER"
    case connectivity = "RTC_CONNECTIVITY"

    var status: String {
        switch self {
        case .waitingForOffer: return "Waiting for the other device's media offer."
        case .applyingRemote: return "Applying the verified media description."
        case .creatingLocal: return "Creating the media description."
        case .gathering: return "Gathering network routes (ICE/TURN)."
        case .sending: return "Sending the signed media description."
        case .waitingForAnswer: return "Waiting for the other device's media answer."
        case .connectivity: return "Checking the media route and encryption."
        }
    }

    var advice: String {
        switch self {
        case .waitingForOffer, .waitingForAnswer:
            return "Check the error on the other phone; its audio setup or TURN gathering may be stalled."
        case .gathering:
            return "Check TURN DNS, credentials and listener access. Gathering did not finish before the deadline."
        case .connectivity:
            return "Descriptions were exchanged, but media is not connected. Check TURN public-IP mapping "
                + "and firewall access, including the UDP relay-port range."
        case .sending: return "The signed description could not be delivered through the relay."
        case .applyingRemote, .creatingLocal: return "The native WebRTC negotiation did not complete."
        }
    }
}

/// Redacted setup state for diagnosis. Never includes SDP, addresses or credentials.
struct WebRTCSetupProgress {
    let isOfferer: Bool
    let localReady: Bool
    let localDelivered: Bool
    let remoteReceived: Bool
    let remoteApplied: Bool
    let gatheringComplete: Bool

    var stage: WebRTCSetupStage {
        if !isOfferer && !remoteReceived { return .waitingForOffer }
        if remoteReceived && !remoteApplied { return .applyingRemote }
        if !localReady { return .creatingLocal }
        if !gatheringComplete { return .gathering }
        if !localDelivered { return .sending }
        if !remoteReceived { return .waitingForAnswer }
        return .connectivity
    }

    static func candidateSummary(_ sdp: String?) -> String {
        var counts = ["host": 0, "srflx": 0, "relay": 0]
        for line in (sdp ?? "").components(separatedBy: .newlines) where line.hasPrefix("a=candidate:") {
            let fields = line.split(separator: " ")
            if let index = fields.firstIndex(of: "typ"), index + 1 < fields.count {
                let type = String(fields[index + 1])
                if counts[type] != nil { counts[type, default: 0] += 1 }
            }
        }
        return "host=\(counts["host"]!), srflx=\(counts["srflx"]!), relay=\(counts["relay"]!)"
    }

    func failure(localSDP: String?, remoteSDP: String?) -> String {
        "[\(stage.rawValue)] \(stage.status) \(stage.advice)\n"
            + "Local SDP candidates: \(Self.candidateSummary(localSDP)). "
            + "Remote SDP candidates: \(Self.candidateSummary(remoteSDP))."
    }
}

/// Signs the entire SDP, including ICE credentials and DTLS fingerprint, to the
/// exact admitted pair and fresh roster epoch. No unauthenticated SDP reaches WebRTC.
struct WebRTCSignal {
    static let maximumSize = 32768
    static let trickleAttribute = "a=x-canddle-trickle:1"
    let message: [String: String]
    var identity: String { message["identity"]! }
    var recipient: String { message["to"]! }
    var kind: String { message["kind"]! }
    var sdp: String { message["sdp"]! }
    var supportsTrickle: Bool { sdp.components(separatedBy: .newlines).contains(Self.trickleAttribute) }
    var digest: String { VoiceProtocol.base64(Data(SHA256.hash(data: Data(sdp.utf8)))) }
    var mid: String? {
        sdp.components(separatedBy: .newlines).first(where: { $0.hasPrefix("a=mid:") }).map {
            String($0.dropFirst(6))
        }
    }

    private static let fields = ["call", "revision", "epoch", "identity", "to", "kind", "sdp"]

    init(_ message: [String: String], session: WebRTCSession) throws {
        guard Set(message.keys) == Set(Self.fields + ["type", "signature"]),
              message["type"] == "rtc-signal", session.offer.usesWebRTC,
              message["call"] == session.offer.id,
              message["revision"] == String(session.roster.revision),
              message["epoch"] == session.roster.message["epoch"],
              message["identity"] != message["to"],
              let sender = message["identity"], let target = message["to"],
              session.roster.members.contains(where: { $0.id == sender }),
              session.roster.members.contains(where: { $0.id == target }),
              sender == session.identity || target == session.identity,
              message["kind"] == (sender < target ? "offer" : "answer") else { throw VoiceError.peer }
        try Self.validateSDP(message["sdp"]!)
        try LobbyProtocol.verify(sender, message["signature"]!,
            LobbyProtocol.transcript("rtc-signal", Self.fields.map { message[$0]! }))
        self.message = message
    }

    static func create(sdp: String, kind: String, to: String, session: WebRTCSession,
                       signing: Curve25519.Signing.PrivateKey) throws -> Self {
        var message = [
            "type": "rtc-signal", "call": session.offer.id,
            "revision": String(session.roster.revision), "epoch": session.roster.message["epoch"]!,
            "identity": VoiceProtocol.base64(signing.publicKey.rawRepresentation),
            "to": to, "kind": kind, "sdp": sdp
        ]
        message["signature"] = VoiceProtocol.base64(try signing.signature(for:
            LobbyProtocol.transcript("rtc-signal", fields.map { message[$0]! })))
        return try Self(message, session: session)
    }

    static func validateSDP(_ sdp: String) throws {
        guard (1...24000).contains(sdp.utf8.count) else { throw VoiceError.packet }
        let lines = sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let media = lines.filter { $0.hasPrefix("m=") }
        let fingerprints = lines.filter { $0.hasPrefix("a=fingerprint:") }
        if lines.contains(trickleAttribute) {
            let mids = lines.filter { $0.hasPrefix("a=mid:") }
            guard lines.filter({ $0 == trickleAttribute }).count == 1, mids.count == 1,
                  String(mids[0].dropFirst(6)).range(of: #"^[A-Za-z0-9_.-]{1,32}$"#,
                      options: .regularExpression) != nil else { throw VoiceError.packet }
        }
        guard media.count == 1,
              media[0].range(of: #"^m=audio [0-9]+ UDP/TLS/RTP/SAVPF( [0-9]+)+$"#,
                             options: .regularExpression) != nil,
              fingerprints.count == 1,
              fingerprints[0].range(of: #"^a=fingerprint:sha-256 ([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$"#,
                                    options: .regularExpression) != nil,
              lines.contains("a=rtcp-mux"),
              lines.contains(where: { $0.range(of: #"^a=rtpmap:[0-9]+ opus/48000/2$"#,
                                               options: .regularExpression) != nil }) else {
            throw VoiceError.packet
        }
    }
}

/// Each update authenticates its exact SDP as well as its admitted pair/epoch.
struct WebRTCCandidate {
    static let limit = 64
    private static let fields = [
        "call", "revision", "epoch", "identity", "to", "description", "sequence", "mid", "index", "candidate"
    ]
    let message: [String: String]
    var identity: String { message["identity"]! }
    var recipient: String { message["to"]! }
    var candidate: String { message["candidate"]! }
    var mid: String { message["mid"]! }
    var sequence: Int { Int(message["sequence"]!)! }
    var ended: Bool { candidate.isEmpty }

    init(_ message: [String: String], session: WebRTCSession, description: WebRTCSignal) throws {
        guard session.trickle, description.supportsTrickle,
              Set(message.keys) == Set(Self.fields + ["type", "signature"]),
              message["type"] == "rtc-candidate",
              message["call"] == session.offer.id,
              message["revision"] == String(session.roster.revision),
              message["epoch"] == session.roster.message["epoch"],
              description.message["call"] == message["call"],
              description.message["revision"] == message["revision"],
              description.message["epoch"] == message["epoch"],
              message["identity"] == description.identity, message["to"] == description.recipient,
              description.identity != description.recipient,
              session.roster.members.contains(where: { $0.id == description.identity }),
              session.roster.members.contains(where: { $0.id == description.recipient }),
              description.identity == session.identity || description.recipient == session.identity,
              message["description"] == description.digest, message["mid"] == description.mid,
              message["index"] == "0", let raw = message["candidate"],
              let sequence = message["sequence"].flatMap(Int.init),
              String(sequence) == message["sequence"], (1...Self.limit + 1).contains(sequence)
        else { throw VoiceError.peer }
        if !raw.isEmpty {
            guard sequence <= Self.limit, raw.utf8.count <= 2048,
                  raw.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
                  raw.range(of: #"^candidate:[A-Za-z0-9+/]+ 1 (udp|tcp|UDP|TCP) .+$"#,
                            options: .regularExpression) != nil else { throw VoiceError.packet }
        }
        try LobbyProtocol.verify(description.identity, message["signature"]!,
            LobbyProtocol.transcript("rtc-candidate", Self.fields.map { message[$0]! }))
        self.message = message
    }

    static func create(candidate: String, mid: String, sequence: Int, session: WebRTCSession,
                       description: WebRTCSignal, signing: Curve25519.Signing.PrivateKey) throws -> Self {
        var message = [
            "type": "rtc-candidate", "call": session.offer.id,
            "revision": String(session.roster.revision), "epoch": session.roster.message["epoch"]!,
            "identity": VoiceProtocol.base64(signing.publicKey.rawRepresentation),
            "to": description.recipient, "description": description.digest,
            "sequence": String(sequence), "mid": mid, "index": "0", "candidate": candidate
        ]
        message["signature"] = VoiceProtocol.base64(try signing.signature(for:
            LobbyProtocol.transcript("rtc-candidate", fields.map { message[$0]! })))
        return try Self(message, session: session, description: description)
    }
}

/// Ordered WebSocket delivery lets us reject replay/gaps with constant-size state.
struct WebRTCCandidateStream {
    private(set) var sequence = 0
    private(set) var ended = false

    mutating func accept(_ update: WebRTCCandidate) throws {
        guard !ended, update.sequence == sequence + 1 else { throw VoiceError.packet }
        sequence = update.sequence
        ended = update.ended
    }
}

/// One flattened `RTCStatistics` entry. Only numbers and short strings are kept.
struct WebRTCStat: Sendable {
    let type: String
    var numbers: [String: Double] = [:]
    var strings: [String: String] = [:]
}

/// Cumulative counters for one peer link, read from a WebRTC stats report.
/// Never holds addresses, ports, SDP, ICE credentials or audio content.
struct WebRTCQualitySample: Sendable, Equatable {
    var seconds: Double = 0
    var packetsReceived: Double = 0
    var packetsLost: Double = 0
    var packetsSent: Double = 0
    var bytesReceived: Double = 0
    var bytesSent: Double = 0
    var concealedSamples: Double = 0
    var totalSamplesReceived: Double = 0
    var jitterBufferDelay: Double = 0
    var jitterBufferEmitted: Double = 0
    var micEnergy: Double = 0
    var micDuration: Double = 0
    var speakerEnergy: Double = 0
    var speakerDuration: Double = 0
    var jitter: Double?
    var roundTrip: Double?
    var remoteLoss: Double?
    var route = "unknown"

    static let candidateTypes: Set<String> = ["host", "srflx", "prflx", "relay"]
    static let transports: Set<String> = ["udp", "tcp", "tls"]

    init() {}

    init(_ stats: [String: WebRTCStat], seconds: Double) {
        self.seconds = seconds
        func audio(_ stat: WebRTCStat) -> Bool { (stat.strings["kind"] ?? stat.strings["mediaType"]) == "audio" }
        for stat in stats.values {
            let n = stat.numbers
            switch stat.type {
            case "inbound-rtp" where audio(stat):
                packetsReceived += n["packetsReceived"] ?? 0
                packetsLost += max(0, n["packetsLost"] ?? 0)
                bytesReceived += n["bytesReceived"] ?? 0
                concealedSamples += n["concealedSamples"] ?? 0
                totalSamplesReceived += n["totalSamplesReceived"] ?? 0
                jitterBufferDelay += n["jitterBufferDelay"] ?? 0
                jitterBufferEmitted += n["jitterBufferEmittedCount"] ?? 0
                speakerEnergy += n["totalAudioEnergy"] ?? 0
                speakerDuration += n["totalSamplesDuration"] ?? 0
                if let value = n["jitter"] { jitter = max(jitter ?? 0, value) }
            case "outbound-rtp" where audio(stat):
                packetsSent += n["packetsSent"] ?? 0
                bytesSent += n["bytesSent"] ?? 0
            case "remote-inbound-rtp" where audio(stat):
                if let value = n["fractionLost"] { remoteLoss = max(remoteLoss ?? 0, value) }
                if roundTrip == nil, let value = n["roundTripTime"] { roundTrip = value }
            case "media-source" where audio(stat):
                micEnergy += n["totalAudioEnergy"] ?? 0
                micDuration += n["totalSamplesDuration"] ?? 0
            default: break
            }
        }
        let pairs = stats.values.filter { $0.type == "candidate-pair" }
        let selectedID = stats.values.first { $0.type == "transport" }?.strings["selectedCandidatePairId"]
        let pair = selectedID.flatMap { stats[$0] }
            ?? pairs.first { $0.numbers["nominated"] == 1 && $0.strings["state"] == "succeeded" }
        if let pair {
            if let value = pair.numbers["currentRoundTripTime"] { roundTrip = value }
            func describe(_ id: String?) -> String {
                guard let candidate = id.flatMap({ stats[$0] }),
                      let type = candidate.strings["candidateType"], Self.candidateTypes.contains(type) else {
                    return "unknown"
                }
                // For a local relay candidate, relayProtocol is the phone-to-TURN leg.
                let transport = candidate.strings["relayProtocol"] ?? candidate.strings["protocol"] ?? ""
                return Self.transports.contains(transport) ? "\(type)/\(transport)" : type
            }
            route = "\(describe(pair.strings["localCandidateId"]))>\(describe(pair.strings["remoteCandidateId"]))"
        }
    }
}

/// Redacted interval summary of one link, used locally and for operator diagnosis.
struct WebRTCQualityLink: Codable, Equatable {
    var to: String
    var route: String
    var secs: Double
    var rttMs: Double?
    var jitterMs: Double?
    var lossIn: Double?
    var lossOut: Double?
    var conceal: Double?
    var jbMs: Double?
    var rxPps: Double
    var txPps: Double
    var rxKbps: Double
    var txKbps: Double
    var micDb: Double?
    var spkDb: Double?
    var muted: Bool

    enum CodingKeys: String, CodingKey {
        case to, route, secs, muted
        case rttMs = "rtt_ms", jitterMs = "jitter_ms", lossIn = "loss_in", lossOut = "loss_out"
        case conceal, jbMs = "jb_ms", rxPps = "rx_pps", txPps = "tx_pps"
        case rxKbps = "rx_kbps", txKbps = "tx_kbps", micDb = "mic_db", spkDb = "spk_db"
    }

    static let interval: UInt64 = 10

    static func round(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }

    /// RMS level in dBFS from cumulative audio energy, or nil when no audio was measured.
    static func level(_ energy: Double, _ duration: Double) -> Double? {
        guard duration > 0.5, energy >= 0 else { return nil }
        return round(max(-127, 10 * log10(max(energy / duration, 1e-13))))
    }

    init?(peer: String, from old: WebRTCQualitySample, to new: WebRTCQualitySample, muted: Bool) {
        let span = new.seconds - old.seconds
        guard span >= 1, span <= 3600 else { return nil }
        func delta(_ path: KeyPath<WebRTCQualitySample, Double>) -> Double { max(0, new[keyPath: path] - old[keyPath: path]) }
        let received = delta(\.packetsReceived), lost = delta(\.packetsLost)
        let samples = delta(\.totalSamplesReceived), emitted = delta(\.jitterBufferEmitted)
        to = peer
        route = new.route
        secs = Self.round(span)!
        rttMs = Self.round(new.roundTrip.map { $0 * 1000 })
        jitterMs = Self.round(new.jitter.map { $0 * 1000 })
        lossIn = received + lost > 0 ? Self.round(100 * lost / (received + lost)) : nil
        lossOut = Self.round(new.remoteLoss.map { min(100, $0 * 100) })
        conceal = samples > 0 ? Self.round(min(100, 100 * delta(\.concealedSamples) / samples)) : nil
        jbMs = emitted > 0 ? Self.round(1000 * delta(\.jitterBufferDelay) / emitted) : nil
        rxPps = Self.round(received / span)!
        txPps = Self.round(delta(\.packetsSent) / span)!
        rxKbps = Self.round(delta(\.bytesReceived) * 8 / span / 1000)!
        txKbps = Self.round(delta(\.bytesSent) * 8 / span / 1000)!
        micDb = Self.level(delta(\.micEnergy), delta(\.micDuration))
        spkDb = Self.level(delta(\.speakerEnergy), delta(\.speakerDuration))
        self.muted = muted
    }

    static func message(call: String, links: [Self]) throws -> [String: String] {
        guard (1...5).contains(links.count) else { throw VoiceError.packet }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(links), as: UTF8.self)
        guard text.utf8.count <= 4096 else { throw VoiceError.packet }
        return ["type": "rtc-quality", "call": call, "links": text]
    }
}

/// A local estimate, not a speech-quality score or proof of remote playback.
enum CallQuality: String {
    case good = "Good", fair = "Fair", poor = "Poor"
    case measuring = "Measuring", stale = "Stale", connecting = "Connecting"
    case unavailable = "Unavailable"

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .fair: return "exclamationmark.circle.fill"
        case .poor: return "exclamationmark.triangle.fill"
        case .measuring: return "hourglass"
        case .stale: return "clock.badge.exclamationmark"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .unavailable: return "questionmark.circle"
        }
    }

    static func estimate(_ link: WebRTCQualityLink) -> Self {
        let metrics: [(Double?, Double, Double)] = [
            (link.rttMs, 300, 600), (link.jitterMs, 30, 60),
            (link.lossIn, 2, 5), (link.lossOut, 2, 5),
            (link.conceal, 5, 10), (link.jbMs, 150, 300)
        ]
        let valid = metrics.filter { $0.0.map { $0.isFinite && $0 >= 0 } ?? false }
        if valid.contains(where: { $0.0! >= $0.2 }) { return .poor }
        if valid.contains(where: { $0.0! >= $0.1 }) { return .fair }
        // RTT alone cannot establish healthy audio delivery. Silence/mute and
        // low bitrate are not failures, but missing receive metrics stay unknown.
        let required = [link.rttMs, link.jitterMs, link.lossIn, link.conceal]
        return required.allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? false }
            ? .good : .measuring
    }
}

struct CallQualityIndicator: Equatable {
    var transport: String
    var quality: CallQuality
    var partial = false

    var qualityLabel: String { quality.rawValue + (partial ? " (partial)" : "") }

    static func localTransport(_ route: String) -> String {
        let local = route.components(separatedBy: ">")[0].components(separatedBy: "/")
        guard local.count == 2, WebRTCQualitySample.candidateTypes.contains(local[0]) else { return "?" }
        switch local[1] {
        case "udp": return "UDP"
        case "tcp", "tls": return "TCP"
        default: return "?"
        }
    }

    static func summary(_ links: [Self]) -> Self {
        guard !links.isEmpty else { return Self(transport: "?", quality: .measuring) }
        let transport = Set(links.map(\.transport)).sorted().joined(separator: " / ")
        let unknown = links.contains { ![.good, .fair, .poor].contains($0.quality) }
        for quality in [CallQuality.poor, .fair, .connecting, .stale, .measuring, .unavailable, .good] {
            if links.contains(where: { $0.quality == quality }) {
                return Self(transport: transport, quality: quality,
                            partial: unknown && [.poor, .fair].contains(quality))
            }
        }
        return Self(transport: transport, quality: .measuring)
    }
}

struct CallQualityReading: Equatable {
    let link: WebRTCQualityLink
    let received: Date
    static let maximumAge: TimeInterval = 25

    func indicator(at now: Date) -> CallQualityIndicator {
        let age = now.timeIntervalSince(received)
        guard age >= 0, age <= Self.maximumAge else {
            return CallQualityIndicator(transport: "?", quality: .stale)
        }
        return CallQualityIndicator(transport: CallQualityIndicator.localTransport(link.route),
                                    quality: CallQuality.estimate(link))
    }
}
