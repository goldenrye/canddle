import CryptoKit
import Foundation

enum GroupPresenceState: String {
    case online, calling, joining
    case inCall = "in-call"
    case disconnected, unknown

    var label: String {
        switch self {
        case .online: return "Online"
        case .calling: return "Calling"
        case .joining: return "Joining"
        case .inCall: return "In call"
        case .disconnected: return "Not connected"
        case .unknown: return "Unknown"
        }
    }
}

struct GroupPresence: Identifiable {
    let id: String
    let name: String
    let state: GroupPresenceState
}

struct GroupPresenceSnapshot {
    let members: [GroupPresence]
    let truncated: Bool

    init(_ message: [String: String]) throws {
        guard Set(message.keys) == ["type", "members", "truncated"],
              message["type"] == "presence",
              let data = message["members"]?.data(using: .utf8), data.count <= 8000,
              ["yes", "no"].contains(message["truncated"]) else { throw VoiceError.packet }
        let entries = try JSONDecoder().decode([[String]].self, from: data)
        guard entries.count <= 32 else { throw VoiceError.packet }
        var ids = Set<String>()
        members = try entries.map { entry in
            guard entry.count == 3, LobbyProtocol.nameValid(entry[1]),
                  let state = GroupPresenceState(rawValue: entry[2]),
                  state != .unknown, state != .disconnected,
                  ids.insert(entry[0]).inserted else { throw VoiceError.packet }
            _ = try VoiceProtocol.decode(entry[0], size: 32)
            return GroupPresence(id: entry[0], name: entry[1], state: state)
        }
        truncated = message["truncated"] == "yes"
    }
}

struct GroupMember: Identifiable {
    let message: [String: String]
    var id: String { message["identity"]! }
    var name: String { message["name"]! }
    var ephemeral: String { message["ephemeral"]! }
}

struct GroupRoster {
    let message: [String: String]
    let members: [GroupMember]
    let revision: UInt64
    let binding: Data

    init(_ message: [String: String], offer: LobbyOffer) throws {
        guard Set(message.keys) == ["type", "call", "revision", "epoch", "members", "signature"],
              message["type"] == "roster", message["call"] == offer.id,
              let revision = UInt64(message["revision"]!), revision > 0,
              String(revision) == message["revision"], message["members"]!.utf8.count <= 6000 else {
            throw VoiceError.packet
        }
        _ = try VoiceProtocol.decode(message["epoch"]!, size: 32)
        let binding = LobbyProtocol.transcript("group-roster",
            [offer.id, message["revision"]!, message["epoch"]!, message["members"]!])
        try LobbyProtocol.verify(offer.identity, message["signature"]!, binding)
        let entries = try JSONDecoder().decode([[String: String]].self, from: Data(message["members"]!.utf8))
        guard (1...6).contains(entries.count) else { throw VoiceError.packet }
        var ids = Set<String>()
        var members: [GroupMember] = []
        for entry in entries {
            if entry["identity"] == offer.identity {
                guard entry == offer.message else { throw VoiceError.peer }
            } else {
                _ = try LobbyRequest(entry, offer: offer)
            }
            let member = GroupMember(message: entry)
            guard ids.insert(member.id).inserted else { throw VoiceError.peer }
            members.append(member)
        }
        guard ids.contains(offer.identity) else { throw VoiceError.peer }
        self.message = message
        self.members = members
        self.revision = revision
        self.binding = binding
    }

    static func create(offer: LobbyOffer, revision: UInt64, members: [GroupMember],
                       signing: Curve25519.Signing.PrivateKey) throws -> GroupRoster {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(members.sorted { $0.id < $1.id }.map(\.message))
        let epoch = VoiceProtocol.base64(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        var message = ["type": "roster", "call": offer.id, "revision": String(revision),
                       "epoch": epoch, "members": String(decoding: encoded, as: UTF8.self)]
        message["signature"] = VoiceProtocol.base64(try signing.signature(for:
            LobbyProtocol.transcript("group-roster",
                [offer.id, String(revision), epoch, message["members"]!])))
        return try Self(message, offer: offer)
    }
}

struct GroupCipher {
    let revision: UInt64
    private var links: [String: CallKeys] = [:]

    init(roster: GroupRoster, identity: String, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws {
        guard let own = roster.members.first(where: { $0.id == identity }),
              own.ephemeral == VoiceProtocol.base64(ephemeral.publicKey.rawRepresentation) else {
            throw VoiceError.peer
        }
        revision = roster.revision
        for peer in roster.members where peer.id != identity {
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with:
                Curve25519.KeyAgreement.PublicKey(rawRepresentation:
                    VoiceProtocol.decode(peer.ephemeral, size: 32)))
            let first = identity < peer.id
            let context = LobbyProtocol.transcript("group-media", first ? [identity, peer.id] : [peer.id, identity])
                + roster.binding
            let binding = Data(SHA256.hash(data: context))
            let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: binding,
                sharedInfo: context, outputByteCount: 64).withUnsafeBytes { Data($0) }
            let low = Data(material.prefix(32)), high = Data(material.suffix(32))
            links[peer.id] = CallKeys(send: first ? low : high, receive: first ? high : low,
                                     binding: binding, code: "")
        }
    }

    mutating func seal(_ frame: Data, to peer: String) throws -> Data {
        guard frame.count == VoiceProtocol.frameSize, var link = links[peer] else { throw VoiceError.peer }
        let encrypted = try link.seal(Data([1]) + frame)
        links[peer] = link
        var revision = revision.bigEndian
        return try VoiceProtocol.decode(peer, size: 32)
            + withUnsafeBytes(of: &revision) { Data($0) } + encrypted
    }

    mutating func open(_ packet: Data) throws -> (String, Data)? {
        guard packet.count == 705 else { throw VoiceError.packet }
        let incomingRevision = packet.dropFirst(32).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if incomingRevision < revision { return nil }
        guard incomingRevision == revision else { throw VoiceError.order }
        let sender = VoiceProtocol.base64(Data(packet.prefix(32)))
        guard var link = links[sender] else { throw VoiceError.peer }
        let plain = try link.open(Data(packet.dropFirst(40)))
        guard plain.count == 641, plain.first == 1 else { throw VoiceError.packet }
        links[sender] = link
        return (sender, Data(plain.dropFirst()))
    }
}

/// One 20-ms frame per speaker per playout tick; bounded queues prevent a late
/// speaker from adding unlimited latency. Silence fills missing contributions.
struct GroupMixer {
    private var queues: [String: [Data]] = [:]

    mutating func reset(_ identities: [String]) {
        queues = Dictionary(uniqueKeysWithValues: identities.map { ($0, []) })
    }

    mutating func push(_ frame: Data, from peer: String) throws {
        guard frame.count == VoiceProtocol.frameSize, var queue = queues[peer] else { throw VoiceError.packet }
        if queue.count >= 5 { queue.removeFirst() }
        queue.append(frame)
        queues[peer] = queue
    }

    mutating func mix() -> Data {
        var sums = [Int](repeating: 0, count: 320)
        for peer in Array(queues.keys) {
            guard var queue = queues[peer], !queue.isEmpty else { continue }
            let bytes = [UInt8](queue.removeFirst())
            queues[peer] = queue
            for index in 0..<320 {
                sums[index] += Int(Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8))
            }
        }
        var result = Data(capacity: 640)
        for sum in sums {
            let value = UInt16(bitPattern: Int16(clamping: sum))
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return result
    }
}
