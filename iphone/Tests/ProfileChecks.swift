import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct ProfileChecks {
    static func image(gray: CGFloat, size: Int = 240) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private original"],
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func rejects(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected invalid profile to be rejected") }
        catch {}
    }

    @MainActor static func ready(_ store: ProfilePhotoStore) async throws {
        let deadline = Date().addingTimeInterval(6)
        while store.loading {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        let original = image(gray: 0.3)
        let prepared = try ProfileImage.prepare(original)
        precondition(prepared.count <= 5120)
        let decoded = ProfileImage.sharedImage(prepared)!
        precondition(decoded.width <= 160 && decoded.width == decoded.height)
        let source = CGImageSourceCreateWithData(prepared as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        precondition(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        precondition(exif[kCGImagePropertyExifUserComment] == nil)
        precondition(Set(exif.keys).isSubset(of: [
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace
        ]))
        precondition(ProfileImage.sharedImage(original) == nil) // Oversized shared images are not decoded.
        precondition(ProfileImage.sharedImage(Data([0xff, 0xd8, 0xff, 0xd9])) == nil)
        rejects { _ = try ProfileImage.prepare(Data("not a photo".utf8)) }
        rejects { _ = try ProfileImage.prepare(Data(count: ProfileImage.maximumInputBytes + 1)) }

        let key = Curve25519.Signing.PrivateKey()
        let signed = try DeviceProfile.create(photo: prepared, revision: 1, signing: key)
        let verified = try DeviceProfile(signed.message)
        precondition(verified.photo == prepared)
        var forged = signed.message
        forged["photo"] = ""
        rejects { _ = try DeviceProfile(forged) }
        forged = signed.message; forged["identity"] = VoiceProtocol.base64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        rejects { _ = try DeviceProfile(forged) }
        rejects { _ = try DeviceProfile.create(photo: prepared, revision: 0, signing: key) }
        let removed = try DeviceProfile.create(photo: Data(), revision: 2, signing: key)
        precondition(removed.photo.isEmpty)
        let maximum = Data([0xff, 0xd8]) + Data(count: 5116) + Data([0xff, 0xd9])
        let largest = try DeviceProfile.create(photo: maximum, revision: 1, signing: key)
        let wire = try JSONEncoder().encode(largest.message)
        precondition(wire.count <= 8192)

        let suite = "canddle.profile-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = MemberProfileCache(defaults: defaults)
        let scope = "wss://family.example/relay"
        cache.save([signed.identity: signed], scope: scope, names: [signed.identity: "Family iPhone"])
        precondition(MemberProfileCache(defaults: defaults).load(scope: scope)[signed.identity] == signed)
        precondition(cache.loadNames(scope: scope)[signed.identity] == "Family iPhone")
        precondition(cache.load(scope: "wss://another.example/relay").isEmpty)
        precondition(cache.loadNames(scope: "wss://another.example/relay").isEmpty)
        cache.save([removed.identity: removed], scope: scope)
        precondition(cache.load(scope: scope)[removed.identity]?.photo.isEmpty == true)
        // Reload keeps the highest signed revision even if the saved array contains a replay.
        let duplicates: [String: Any] = ["scope": scope, "profiles": [removed.message, signed.message, forged]]
        defaults.set(try JSONSerialization.data(withJSONObject: duplicates), forKey: "memberProfiles.v1")
        precondition(cache.load(scope: scope)[removed.identity]?.revision == 2)
        precondition(cache.load(scope: scope).count == 1)
        precondition(cache.loadNames(scope: scope).isEmpty) // Previous cache format still loads.
        var invalidNames = duplicates
        invalidNames["names"] = [signed.identity: "Invalid\nname", "invalid-key": "Family"]
        defaults.set(try JSONSerialization.data(withJSONObject: invalidNames), forKey: "memberProfiles.v1")
        precondition(cache.loadNames(scope: scope).isEmpty)
        precondition(cache.load(scope: scope)[removed.identity]?.revision == 2)
        defaults.set(Data(count: 1_100_001), forKey: "memberProfiles.v1")
        precondition(cache.load(scope: scope).isEmpty)
        let tooMany: [String: Any] = ["scope": scope, "profiles": Array(repeating: signed.message, count: 129)]
        defaults.set(try JSONSerialization.data(withJSONObject: tooMany), forKey: "memberProfiles.v1")
        precondition(cache.load(scope: scope).isEmpty)
        cache.clear()
        precondition(cache.load(scope: scope).isEmpty)
        let store = ProfilePhotoStore(defaults: defaults)
        var changes = 0
        store.onChange = { _, _ in changes += 1 }
        precondition(store.photo.isEmpty && store.revision == 0)
        store.select(original, fromContact: true)
        try await ready(store)
        precondition(store.photo == prepared && store.custom == nil)
        let firstRevision = store.revision
        store.select(image(gray: 0.9), fromContact: false)
        try await ready(store)
        precondition(store.custom != nil && store.photo != prepared && store.contact == prepared)
        precondition(store.revision > firstRevision)
        let reloaded = ProfilePhotoStore(defaults: defaults)
        precondition(reloaded.photo == store.photo && reloaded.contact == prepared)
        store.useContactPhoto()
        precondition(store.photo == prepared && store.custom == nil)
        store.select(Data([1, 2, 3]), fromContact: false)
        try await ready(store)
        precondition(store.error != nil && store.photo == prepared)
        store.removePhoto()
        precondition(store.photo.isEmpty && store.contact == nil && store.custom == nil)
        precondition(ProfilePhotoStore(defaults: defaults).photo.isEmpty)
        precondition(changes == 4)
        print("PASS signed profiles, bounded images, metadata stripping, defaults, customization and persistence")
    }
}
