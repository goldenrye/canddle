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
    let message: [String: String]
    var identity: String { message["identity"]! }
    var recipient: String { message["to"]! }
    var kind: String { message["kind"]! }
    var sdp: String { message["sdp"]! }

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
