import CryptoKit
import Foundation

/// Cosmetic identity-bound metadata, never an admission or verification signal.
struct DeviceProfile: Equatable {
    static let maximumPhotoBytes = 5120
    let message: [String: String]
    let photo: Data
    let revision: UInt64
    var identity: String { message["identity"]! }

    init(_ message: [String: String]) throws {
        guard Set(message.keys) == ["type", "identity", "revision", "photo", "signature"],
              message["type"] == "profile",
              let raw = message["photo"], raw.utf8.count <= 6827,
              let revision = message["revision"].flatMap(UInt64.init), revision > 0,
              String(revision) == message["revision"] else { throw VoiceError.packet }
        let photo = try VoiceProtocol.decode(raw, size: raw.utf8.count * 6 / 8)
        guard Self.validPhoto(photo) else { throw VoiceError.packet }
        try LobbyProtocol.verify(message["identity"]!, message["signature"]!,
            LobbyProtocol.transcript("device-profile",
                [message["identity"]!, String(revision), raw]))
        self.message = message
        self.photo = photo
        self.revision = revision
    }

    static func validPhoto(_ data: Data) -> Bool {
        data.isEmpty || (data.count <= maximumPhotoBytes && data.count >= 4
            && data.prefix(2) == Data([0xff, 0xd8]) && data.suffix(2) == Data([0xff, 0xd9]))
    }

    static func create(photo: Data, revision: UInt64,
                       signing: Curve25519.Signing.PrivateKey) throws -> DeviceProfile {
        let identity = VoiceProtocol.base64(signing.publicKey.rawRepresentation)
        let raw = VoiceProtocol.base64(photo)
        return try DeviceProfile([
            "type": "profile", "identity": identity, "revision": String(revision), "photo": raw,
            "signature": VoiceProtocol.base64(try signing.signature(for:
                LobbyProtocol.transcript("device-profile", [identity, String(revision), raw])))
        ])
    }
}
