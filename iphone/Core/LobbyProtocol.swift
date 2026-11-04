import CryptoKit
import Foundation

enum LobbyProtocol {
    static func transcript(_ purpose: String, _ fields: [String] = []) -> Data {
        var data = Data("vpcomm/lobby/v1/\(purpose)\0".utf8)
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            data.append(withUnsafeBytes(of: &length) { Data($0) })
            data.append(bytes)
        }
        return data
    }

    static func nameValid(_ name: String) -> Bool {
        (1...40).contains(name.utf8.count) && name.utf8.allSatisfy { (32...126).contains($0) }
    }

    static func randomID() -> String {
        VoiceProtocol.base64(Data(UUID().uuidString.utf8).sha256.prefix(16))
    }

    static func verify(_ identity: String, _ signature: String, _ message: Data) throws {
        let key = try Curve25519.Signing.PublicKey(
            rawRepresentation: VoiceProtocol.decode(identity, size: 32)
        )
        guard key.isValidSignature(try VoiceProtocol.decode(signature, size: 64), for: message) else {
            throw VoiceError.peer
        }
    }

    static func fingerprint(_ identity: String) -> String {
        guard let data = try? VoiceProtocol.decode(identity, size: 32) else { return "Invalid key" }
        return data.sha256.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var sha256: Data { Data(SHA256.hash(data: self)) }
}

struct LobbyOffer: Identifiable {
    let message: [String: String]
    var id: String { message["call"]! }
    var identity: String { message["identity"]! }
    var ephemeral: String { message["ephemeral"]! }
    var name: String { message["name"]! }
    var target: String? { message["target"] }
    var fields: [String] { [id, identity, ephemeral, name] + (target.map { [$0] } ?? []) }

    init(_ message: [String: String]) throws {
        let keys: Set<String> = ["type", "call", "identity", "ephemeral", "name", "signature"]
        guard Set(message.keys) == keys.union(message["target"] == nil ? [] : ["target"]),
              message["type"] == "offer", LobbyProtocol.nameValid(message["name"]!) else {
            throw VoiceError.packet
        }
        self.message = message
        _ = try VoiceProtocol.decode(id, size: 16)
        _ = try VoiceProtocol.decode(ephemeral, size: 32)
        if let target {
            _ = try VoiceProtocol.decode(target, size: 32)
            guard target != identity else { throw VoiceError.peer }
        }
        try LobbyProtocol.verify(identity, message["signature"]!,
                                 LobbyProtocol.transcript(target == nil ? "offer" : "direct-offer", fields))
    }

    static func create(identity: Curve25519.Signing.PrivateKey, name: String,
                       ephemeral: Curve25519.KeyAgreement.PrivateKey,
                       target: String? = nil) throws -> LobbyOffer {
        var message = [
            "type": "offer", "call": LobbyProtocol.randomID(), "name": name,
            "identity": VoiceProtocol.base64(identity.publicKey.rawRepresentation),
            "ephemeral": VoiceProtocol.base64(ephemeral.publicKey.rawRepresentation)
        ]
        if let target { message["target"] = target }
        let fields = ["call", "identity", "ephemeral", "name"].map { message[$0]! } + (target.map { [$0] } ?? [])
        message["signature"] = VoiceProtocol.base64(
            try identity.signature(for: LobbyProtocol.transcript(target == nil ? "offer" : "direct-offer", fields))
        )
        return try Self(message)
    }
}

struct LobbyRequest: Identifiable {
    let message: [String: String]
    var id: String { message["request"]! }
    var identity: String { message["identity"]! }
    var ephemeral: String { message["ephemeral"]! }
    var name: String { message["name"]! }
    var fields: [String] { [id, identity, ephemeral, name] }

    init(_ message: [String: String], offer: LobbyOffer) throws {
        guard Set(message.keys) == ["type", "call", "request", "identity", "ephemeral", "name", "signature"],
              message["type"] == "request", message["call"] == offer.id,
              message["identity"] != offer.identity,
              offer.target == nil || message["identity"] == offer.target,
              LobbyProtocol.nameValid(message["name"]!) else { throw VoiceError.packet }
        self.message = message
        _ = try VoiceProtocol.decode(id, size: 16)
        _ = try VoiceProtocol.decode(ephemeral, size: 32)
        try LobbyProtocol.verify(identity, message["signature"]!,
                                 LobbyProtocol.transcript("request", offer.fields + fields))
    }

    static func create(offer: LobbyOffer, identity: Curve25519.Signing.PrivateKey, name: String,
                       ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> LobbyRequest {
        var message = [
            "type": "request", "call": offer.id, "request": LobbyProtocol.randomID(), "name": name,
            "identity": VoiceProtocol.base64(identity.publicKey.rawRepresentation),
            "ephemeral": VoiceProtocol.base64(ephemeral.publicKey.rawRepresentation)
        ]
        let fields = ["request", "identity", "ephemeral", "name"].map { message[$0]! }
        message["signature"] = VoiceProtocol.base64(
            try identity.signature(for: LobbyProtocol.transcript("request", offer.fields + fields))
        )
        return try Self(message, offer: offer)
    }
}

struct IncomingCallPush {
    let offer: LobbyOffer

    init(_ payload: [AnyHashable: Any], scope: String, recipient: String,
         now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard payload["v"] as? Int == 1,
              payload["scope"] as? String == scope,
              payload["recipient"] as? String == recipient,
              let expires = payload["expires"] as? Double,
              expires.isFinite, expires >= now, expires <= now + 60,
              let message = payload["offer"] as? [String: String],
              (6...7).contains(message.count), message.values.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw VoiceError.packet
        }
        offer = try LobbyOffer(message)
        guard offer.identity != recipient else { throw VoiceError.peer }
        guard offer.target == nil || offer.target == recipient else { throw VoiceError.peer }
    }
}

struct LobbyExchange {
    let offer: LobbyOffer
    let request: LobbyRequest
    let code: String
    private let binding: Data
    private let key: SymmetricKey
    private let confirmationKey: SymmetricKey

    init(offer: LobbyOffer, request: LobbyRequest,
         ephemeral: Curve25519.KeyAgreement.PrivateKey, caller: Bool) throws {
        self.offer = offer
        self.request = request
        guard VoiceProtocol.base64(ephemeral.publicKey.rawRepresentation)
                == (caller ? offer.ephemeral : request.ephemeral) else { throw VoiceError.peer }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation:
            VoiceProtocol.decode(caller ? request.ephemeral : offer.ephemeral, size: 32))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        binding = LobbyProtocol.transcript("exchange", offer.fields + request.fields)
        let material = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: binding.sha256, sharedInfo: binding, outputByteCount: 64
        ).withUnsafeBytes { Data($0) }
        key = SymmetricKey(data: material.prefix(32))
        confirmationKey = SymmetricKey(data: material.suffix(32))
        let digits = Array((LobbyProtocol.transcript("verify") + binding + material)
            .sha256.prefix(12).map { String(format: "%02x", $0) }.joined())
        code = stride(from: 0, to: 24, by: 4).map {
            String(digits[$0..<$0 + 4])
        }.joined(separator: "-")
    }

    func confirmation() -> String {
        VoiceProtocol.base64(Data(HMAC<SHA256>.authenticationCode(
            for: LobbyProtocol.transcript("confirmed") + binding, using: confirmationKey
        )))
    }

    func verifyConfirmation(_ proof: String) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(
            try VoiceProtocol.decode(proof, size: 32),
            authenticating: LobbyProtocol.transcript("confirmed") + binding, using: confirmationKey
        ) else { throw VoiceError.peer }
    }

    func seal(_ invitation: CallInvitation) throws -> String {
        let box = try AES.GCM.seal(Data(invitation.text.utf8), using: key, authenticating: binding)
        guard let bytes = box.combined else { throw VoiceError.packet }
        return VoiceProtocol.base64(bytes)
    }

    func open(_ encoded: String) throws -> CallInvitation {
        let box = try AES.GCM.SealedBox(combined: VoiceProtocol.decode(encoded, size: 98))
        let plain = try AES.GCM.open(box, using: key, authenticating: binding)
        guard let text = String(data: plain, encoding: .utf8) else { throw VoiceError.packet }
        return try CallInvitation(text)
    }
}
