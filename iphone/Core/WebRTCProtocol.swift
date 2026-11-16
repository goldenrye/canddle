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
