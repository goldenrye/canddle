import CryptoKit
import Foundation

/// Version 1 private text: authenticated static recipient keys, fresh ephemeral sender keys.
/// This is not a ratchet: compromise of the device secret exposes retained messages.
enum ChatProtocol {
    static let lifetime: TimeInterval = 7 * 86400
    static let fields = ["id", "from", "to", "scope", "key", "ephemeral", "created", "body"]
    static let receiptFields = ["id", "from", "to", "scope"]

    static func derive(_ signing: Curve25519.Signing.PrivateKey, scope: String, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: signing.rawRepresentation),
            salt: Data("vpcomm/chat/v1".utf8),
            info: LobbyProtocol.transcript(purpose, [scope]), outputByteCount: 32)
    }

    static func agreement(_ signing: Curve25519.Signing.PrivateKey, scope: String) throws
        -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            derive(signing, scope: scope, purpose: "chat-agreement").withUnsafeBytes { Data($0) })
    }

    static func keyBundle(_ signing: Curve25519.Signing.PrivateKey, scope: String) throws -> [String: String] {
        let identity = VoiceProtocol.base64(signing.publicKey.rawRepresentation)
        let key = VoiceProtocol.base64(try agreement(signing, scope: scope).publicKey.rawRepresentation)
        return ["type": "chat-key", "identity": identity, "scope": scope, "key": key,
                "signature": VoiceProtocol.base64(try signing.signature(for:
                    LobbyProtocol.transcript("chat-key", [identity, scope, key])))]
    }

    static func verifyBundle(_ bundle: [String: String], identity: String, scope: String) throws -> String {
        guard Set(bundle.keys) == ["type", "identity", "scope", "key", "signature"],
              bundle["type"] == "chat-key", bundle["identity"] == identity, bundle["scope"] == scope,
              let key = bundle["key"] else { throw VoiceError.packet }
        _ = try VoiceProtocol.decode(key, size: 32)
        try LobbyProtocol.verify(identity, bundle["signature"]!,
            LobbyProtocol.transcript("chat-key", [identity, scope, key]))
        return key
    }

    static func metadata(_ message: [String: String]) -> Data {
        LobbyProtocol.transcript("chat-encryption", fields.dropLast().map { message[$0]! })
    }

    static func seal(_ text: String, to recipient: String, bundle: [String: String],
                     signing: Curve25519.Signing.PrivateKey, scope: String,
                     now: Date = Date(), id: String = LobbyProtocol.randomID()) throws -> [String: String] {
        let bytes = Data(text.utf8)
        guard (1...4096).contains(bytes.count),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.packet }
        let key = try verifyBundle(bundle, identity: recipient, scope: scope)
        let own = VoiceProtocol.base64(signing.publicKey.rawRepresentation)
        guard own != recipient else { throw VoiceError.peer }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _ = try VoiceProtocol.decode(id, size: 16)
        var message = ["type": "chat-send", "id": id, "from": own,
                       "to": recipient, "scope": scope, "key": key,
                       "ephemeral": VoiceProtocol.base64(ephemeral.publicKey.rawRepresentation),
                       "created": String(Int(now.timeIntervalSince1970))]
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with:
            Curve25519.KeyAgreement.PublicKey(rawRepresentation: VoiceProtocol.decode(key, size: 32)))
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data("vpcomm/chat/v1".utf8), sharedInfo: metadata(message), outputByteCount: 32)
        message["body"] = VoiceProtocol.base64(try AES.GCM.seal(bytes, using: symmetric,
                                                              authenticating: metadata(message)).combined!)
        message["signature"] = VoiceProtocol.base64(try signing.signature(for:
            LobbyProtocol.transcript("chat-message", fields.map { message[$0]! })))
        return message
    }

    static func open(_ message: [String: String], signing: Curve25519.Signing.PrivateKey,
                     scope: String, now: Date = Date()) throws -> String {
        guard Set(message.keys) == Set(fields + ["type", "signature"]),
              message["type"] == "chat-send", message["scope"] == scope,
              message["to"] == VoiceProtocol.base64(signing.publicKey.rawRepresentation),
              message["from"] != message["to"],
              let created = message["created"].flatMap(Int.init),
              String(created) == message["created"],
              TimeInterval(created) >= now.timeIntervalSince1970 - lifetime,
              TimeInterval(created) <= now.timeIntervalSince1970 + 60,
              let body = message["body"], (39...5500).contains(body.utf8.count) else { throw VoiceError.packet }
        _ = try VoiceProtocol.decode(message["id"]!, size: 16)
        try LobbyProtocol.verify(message["from"]!, message["signature"]!,
            LobbyProtocol.transcript("chat-message", fields.map { message[$0]! }))
        let local = try agreement(signing, scope: scope)
        guard message["key"] == VoiceProtocol.base64(local.publicKey.rawRepresentation) else { throw VoiceError.peer }
        let shared = try local.sharedSecretFromKeyAgreement(with:
            Curve25519.KeyAgreement.PublicKey(rawRepresentation:
                VoiceProtocol.decode(message["ephemeral"]!, size: 32)))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data("vpcomm/chat/v1".utf8), sharedInfo: metadata(message), outputByteCount: 32)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined:
            VoiceProtocol.decode(body, size: body.utf8.count * 6 / 8)),
            using: key, authenticating: metadata(message))
        guard (1...4096).contains(bytes.count), let text = String(data: bytes, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.packet }
        return text
    }

    static func receipt(_ message: [String: String], signing: Curve25519.Signing.PrivateKey) throws
        -> [String: String] {
        var value = message.filter { receiptFields.contains($0.key) }
        guard value["to"] == VoiceProtocol.base64(signing.publicKey.rawRepresentation),
              value.count == 4 else { throw VoiceError.peer }
        value["type"] = "chat-receipt"
        value["signature"] = VoiceProtocol.base64(try signing.signature(for:
            LobbyProtocol.transcript("chat-receipt", receiptFields.map { value[$0]! })))
        return value
    }

    static func verifyReceipt(_ receipt: [String: String], message: [String: String]) throws {
        guard Set(receipt.keys) == Set(receiptFields + ["type", "signature"]),
              receipt["type"] == "chat-receipt",
              receiptFields.allSatisfy({ receipt[$0] == message[$0] }) else { throw VoiceError.packet }
        try LobbyProtocol.verify(receipt["to"]!, receipt["signature"]!,
            LobbyProtocol.transcript("chat-receipt", receiptFields.map { receipt[$0]! }))
    }
}
