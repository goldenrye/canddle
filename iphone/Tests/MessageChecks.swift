import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MessageChecks {
    @MainActor static func wait(_ condition: () -> Bool, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(35)
        while !condition() {
            guard Date() < end else {
                print("Timeout at MessageChecks:\(line)")
                throw VoiceError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("unit") {
            try await unit()
            try await photoChecks()
            print("PASS message crypto and encrypted persistence")
        } else if CommandLine.arguments.contains("interop") {
            let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
            let secret = try VoiceProtocol.decode(input["secret"] as! String, size: 32)
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            let message = input["message"] as! [String: String]
            let scope = message["scope"]!
            let text = try ChatProtocol.open(message, signing: signing, scope: scope)
            let reply = try ChatProtocol.seal("Reply from Swift", to: message["from"]!,
                bundle: input["bundle"] as! [String: String], signing: signing, scope: scope)
            let output: [String: Any] = ["text": text, "reply": reply,
                "receipt": try ChatProtocol.receipt(message, signing: signing)]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
        } else {
            try await network()
            print("PASS native private messaging")
        }
    }

    @MainActor static func unit() async throws {
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey()
        let alice = VoiceProtocol.base64(a.publicKey.rawRepresentation)
        let bob = VoiceProtocol.base64(b.publicKey.rawRepresentation)
        let scope = "wss://test.example/relay"
        let bundle = try ChatProtocol.keyBundle(b, scope: scope)
        let sealed = try ChatProtocol.seal("Hello family", to: bob, bundle: bundle, signing: a, scope: scope)
        let plain = try ChatProtocol.open(sealed, signing: b, scope: scope)
        precondition(plain == "Hello family")
        for field in ChatProtocol.fields + ["signature"] {
            var bad = sealed
            bad[field] = "tampered"
            do {
                _ = try ChatProtocol.open(bad, signing: b, scope: scope)
                preconditionFailure("Accepted tampered \(field)")
            } catch {}
        }
        do {
            _ = try ChatProtocol.open(sealed, signing: b, scope: "wss://another.example/relay")
            preconditionFailure("Accepted foreign scope")
        } catch {}
        let signedReceipt = try ChatProtocol.receipt(sealed, signing: b)
        try ChatProtocol.verifyReceipt(signedReceipt, message: sealed)
        var badReceipt = signedReceipt
        badReceipt["signature"] = sealed["signature"]
        do {
            try ChatProtocol.verifyReceipt(badReceipt, message: sealed)
            preconditionFailure("Accepted forged delivery")
        } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MessageStore(directory: root)
        var frames: [[String: String]] = []
        var unreadChanges: [Int] = []
        store.missedCallCount = { 2 }
        store.onUnreadChange = { unreadChanges.append(store.unreadCount) }
        store.connect(signing: a, scope: scope, supported: true, trusted: { [bob: "Bob"] },
                      send: { frames.append($0) })
        defer { store.disconnect() }
        store.send("Persisted before sending", to: bob)
        try await wait { frames.contains { $0["type"] == "chat-key-get" } }
        store.receive(bundle)
        try await wait { frames.contains { $0["type"] == "chat-send" } }
        let sent = frames.first { $0["type"] == "chat-send" }!
        precondition(store.entries[0].envelope == sent)
        store.receive(["type": "chat-stored", "id": sent["id"]!, "to": bob, "scope": scope])
        precondition(store.entries[0].state == .queued)
        store.receive(try ChatProtocol.receipt(sent, signing: b))
        precondition(store.entries[0].state == .delivered)
        precondition(!frames.contains { $0["type"] == "chat-badge" },
                     "Older relays must not receive unsupported badge frames")
        store.receive(["type": "chat-ready", "push": "yes", "badges": "1"])
        let incoming = try ChatProtocol.seal("Private reply", to: alice,
            bundle: ChatProtocol.keyBundle(a, scope: scope), signing: b, scope: scope)
        store.receive(incoming)
        store.receive(incoming)
        precondition(store.entries.count == 2 && store.unreadCount == 1)
        try await wait { frames.contains { $0["type"] == "chat-badge" && $0["count"] == "3" } }
        let badge = frames.first { $0["type"] == "chat-badge" && $0["count"] == "3" }!
        let receipts = try JSONDecoder().decode([[String: String]].self,
                                                from: Data(badge["receipts"]!.utf8))
        precondition(receipts.count == 1, "Duplicate delivery must not double-count a badge")
        try ChatProtocol.verifyReceipt(receipts[0], message: incoming)
        precondition(unreadChanges.filter { $0 == 1 }.count == 1)
        let unreadReload = MessageStore(directory: root)
        var restoredUnread = -1
        unreadReload.onUnreadChange = { restoredUnread = unreadReload.unreadCount }
        unreadReload.prepare(signing: a, scope: scope)
        precondition(restoredUnread == 1, "Relaunch must restore the unread badge")
        unreadReload.deactivate()
        precondition(restoredUnread == 0, "Forgetting a relay must remove its message badge")
        store.markRead(bob)
        precondition(store.unreadCount == 0)
        try await wait { frames.last { $0["type"] == "chat-badge" }?["count"] == "2" }
        precondition(unreadChanges.last == 0, "Reading must refresh the combined badge")
        store.selectedPeer = bob
        let visible = try ChatProtocol.seal("Already visible", to: alice,
            bundle: ChatProtocol.keyBundle(a, scope: scope), signing: b, scope: scope)
        let changesBeforeVisible = unreadChanges.count
        store.receive(visible)
        precondition(store.unreadCount == 0 && unreadChanges.count == changesBeforeVisible,
                     "Messages in the open conversation must not increment the badge")
        try await wait {
            frames.contains {
                $0["type"] == "chat-badge" && $0["count"] == "2"
                    && ($0["receipts"]?.contains(visible["id"]!) == true)
            }
        }
        store.selectedPeer = nil
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        precondition(files.count == 1)
        let bytes = try Data(contentsOf: files[0])
        precondition(bytes.range(of: Data("Private reply".utf8)) == nil)
        let reloaded = MessageStore(directory: root)
        reloaded.prepare(signing: a, scope: scope)
        precondition(reloaded.entries == store.entries)
        store.clearReadHistory(bob)
        precondition(store.entries.isEmpty)
        store.receive(incoming)
        precondition(store.entries.isEmpty, "Deleted read messages must not reappear on retry")
        reloaded.prepare(signing: a, scope: "wss://another.example/relay")
        precondition(reloaded.entries.isEmpty)
        var corrupted = bytes
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: files[0])
        let broken = MessageStore(directory: root)
        broken.connect(signing: a, scope: scope, supported: true, trusted: { [bob: "Bob"] }, send: { _ in })
        broken.send("Must not overwrite corrupt history", to: bob)
        precondition(broken.entries.isEmpty && broken.error != nil)
        let retained = try Data(contentsOf: files[0])
        precondition(retained == corrupted)
        broken.disconnect()

        for text in [" ", String(repeating: "x", count: 4097)] {
            do {
                _ = try ChatProtocol.seal(text, to: bob, bundle: bundle, signing: a, scope: scope)
                preconditionFailure("Accepted invalid plaintext size")
            } catch {}
        }
        do {
            _ = try ChatProtocol.open(sealed, signing: b, scope: scope,
                                     now: Date().addingTimeInterval(ChatProtocol.lifetime + 120))
            preconditionFailure("Accepted expired message")
        } catch {}
        let isolated = MessageStore(directory: root.appendingPathComponent("switch"))
        var oldFrames: [[String: String]] = []
        isolated.connect(signing: a, scope: scope, supported: true, trusted: { [bob: "Bob"] },
                         send: { oldFrames.append($0) })
        isolated.send("Queued before settings change", to: bob)
        isolated.deactivate()
        precondition(isolated.entries.isEmpty && !isolated.supported && isolated.scope.isEmpty)
        isolated.send("Must not use previous relay", to: bob)
        precondition(isolated.entries.isEmpty)
        isolated.prepare(signing: a, scope: scope)
        precondition(isolated.entries.count == 1, "Encrypted history survives relay settings edits")
        isolated.deactivate()
    }

    @MainActor static func network() async throws {
        struct Input: Decodable { let address: String; let token: String; let enabled: Bool; let photos: Bool? }
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let settings = try RelaySettings(address: input.address, token: input.token, testLoopback: true)
        let scope = settings.url.absoluteString
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey()
        let alice = VoiceProtocol.base64(a.publicKey.rawRepresentation)
        let bob = VoiceProtocol.base64(b.publicKey.rawRepresentation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var identities = [LobbyIdentity(secret: a.rawRepresentation, trusted: [scope + "|" + bob: "Bob"]),
                          LobbyIdentity(secret: b.rawRepresentation, trusted: [scope + "|" + alice: "Alice"])]
        let suites = (0..<2).map { _ in "canddle.message-checks.\(UUID())" }
        let defaults = suites.map { UserDefaults(suiteName: $0)! }
        defer {
            for (index, suite) in suites.enumerated() {
                defaults[index].removePersistentDomain(forName: suite)
            }
        }
        let groups = (0..<2).map { index in
            GroupStore(loadIdentity: { identities[index] }, saveIdentity: { identities[index] = $0 },
                       profileCache: MemberProfileCache(defaults: defaults[index]))
        }
        let stores = (0..<2).map { MessageStore(directory: root.appendingPathComponent("\($0)")) }
        var uploads = 0, statusPolls = 0
        for index in 0..<2 {
            let group = groups[index], store = stores[index]
            group.name = index == 0 ? "Alice" : "Bob"
            group.onMessagingReady = { key, scope, supported in
                store.connect(signing: key, scope: scope, supported: supported, trusted: {
                    [index == 0 ? bob : alice: index == 0 ? "Bob" : "Alice"]
                }, send: {
                    precondition($0["type"] != "chat-photo", "Photo payload cannot share call signaling")
                    try await group.sendMessageFrame($0, scope: scope)
                }, transferPhoto: {
                    if $0["type"] == "chat-photo" { uploads += 1 }
                    if $0["type"] == "chat-photo-status" { statusPolls += 1 }
                    return try await group.transferPhoto($0, scope: scope)
                })
            }
            group.onMessage = { store.receive($0) }
            group.onMessagingOffline = { store.disconnect() }
            group.connect(settings)
        }
        defer {
            groups.forEach { $0.disconnect() }
            stores.forEach { $0.disconnect() }
        }
        try await wait { groups.allSatisfy(\.online) }
        if !input.enabled {
            precondition(stores.allSatisfy { !$0.supported })
            groups[0].announce(target: bob)
            try await wait { groups[1].offers.count == 1 }
            return
        }
        try await wait { stores.allSatisfy(\.online) }
        if input.photos == true {
            let jpeg = try photo()
            try await wait { stores.allSatisfy { $0.status.contains("photos") } }
            groups[1].disconnect()
            precondition(stores[0].sendPhoto(jpeg, to: bob))
            try await wait { stores[0].entries.first?.state == .queued }
            precondition(stores[1].entries.isEmpty)
            await stores[0].flush()
            try await wait { statusPolls > 0 }
            precondition(uploads == 1, "Queued photos must not repeatedly upload their payload")
            groups[0].disconnect()
            groups[0].connect(settings)
            groups[1].connect(settings)
            try await wait { stores[1].entries.count == 1 && stores[0].entries.first?.state == .delivered }
            precondition(stores[1].entries[0].photo == jpeg && stores[1].unreadCount == 1)
            groups[0].announce(target: bob)
            try await wait { groups[1].offers.count == 1 }
            precondition(stores[0].sendPhoto(jpeg, to: bob))
            try await wait { stores[1].entries.count == 2 && stores[0].entries.last?.state == .delivered }
            precondition(groups.allSatisfy(\.online) && groups[0].waiting)
            precondition(stores[1].unreadCount == 2 && stores[1].entries.allSatisfy { $0.photo == jpeg })
            return
        }
        groups[1].disconnect()
        stores[0].send("Offline private hello", to: bob)
        try await wait { stores[0].entries.first?.state == .queued }
        precondition(stores[1].entries.isEmpty)
        groups[0].disconnect()
        groups[0].connect(settings)
        groups[1].connect(settings)
        try await wait {
            stores[1].entries.count == 1 && stores[0].entries.first?.state == .delivered
        }
        precondition(stores[1].entries[0].text == "Offline private hello")
        groups[0].announce(target: bob)
        try await wait { groups[1].offers.count == 1 }
        stores[0].send("Text while ringing", to: bob)
        try await wait { stores[1].entries.count == 2 && stores[0].entries.last?.state == .delivered }
        precondition(groups.allSatisfy(\.online) && groups[0].waiting)
        try await groups[0].sendMessageFrame(stores[0].entries[0].envelope!, scope: scope)
        precondition(stores[1].entries.count == 2)
        precondition(stores[1].unreadCount == 2)
    }

    static func photo() throws -> Data {
        let width = 1600, height = 900
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var random: UInt32 = 1234
            for index in buffer.indices {
                random = random &* 1664525 &+ 1013904223
                buffer[index] = UInt8(truncatingIfNeeded: random >> 24)
            }
        }
        let provider = CGDataProvider(data: bytes as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40, kCGImagePropertyGPSLongitude: 120]
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let prepared = try ChatImage.prepare(output as Data)
        precondition(prepared.count > 32768 && prepared.count <= ChatProtocol.maximumPhotoBytes)
        let source = CGImageSourceCreateWithData(prepared as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        precondition(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let decoded = ChatImage.image(prepared)!
        precondition(decoded.height > decoded.width, "EXIF orientation must be rendered into the pixels")
        precondition(decoded.height <= 1280 && decoded.width <= 1280)
        return prepared
    }

    static func importPicture(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            ChatImage.prepare(provider: provider) { continuation.resume(with: $0) }
        }
    }

    static func pictureProvider(_ bytes: Data, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { reply in
            reply(bytes, nil)
            return nil
        }
        return provider
    }

    static func pictureImportChecks(_ jpeg: Data) async throws {
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ChatImage.image(jpeg)!, nil)
        precondition(CGImageDestinationFinalize(destination))
        for (bytes, type) in [(jpeg, UTType.jpeg), (png as Data, UTType.png)] {
            let imported = try await importPicture(pictureProvider(bytes, type: type))
            precondition(ChatImage.image(imported) != nil)
            precondition(imported.count <= ChatProtocol.maximumPhotoBytes)
        }
        for (bytes, type) in [
            (Data("plain text".utf8), UTType.plainText),
            (Data("https://example.com/photo.jpg".utf8), UTType.url),
            (Data("not an image".utf8), UTType.jpeg),
        ] {
            do {
                _ = try await importPicture(pictureProvider(bytes, type: type))
                preconditionFailure("Accepted unsupported clipboard content")
            } catch {}
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: ChatImage.maximumInputBytes + 1).write(to: file)
        let oversized = NSItemProvider()
        oversized.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier,
            fileOptions: [], visibility: .all) { reply in
                reply(file, false, nil)
                return nil
            }
        do {
            _ = try await importPicture(oversized)
            preconditionFailure("Accepted oversized picture provider")
        } catch {}
    }

    @MainActor static func photoChecks() async throws {
        let a = Curve25519.Signing.PrivateKey(), b = Curve25519.Signing.PrivateKey()
        let alice = VoiceProtocol.base64(a.publicKey.rawRepresentation)
        let bob = VoiceProtocol.base64(b.publicKey.rawRepresentation)
        let scope = "wss://photos.example/relay"
        let jpeg = try photo()
        try await pictureImportChecks(jpeg)
        let bundle = try ChatProtocol.keyBundle(b, scope: scope, photos: true)
        let sealed = try ChatProtocol.sealPhoto(jpeg, to: bob, bundle: bundle, signing: a, scope: scope)
        let opened = try ChatProtocol.openPhoto(sealed, signing: b, scope: scope)
        precondition(opened == jpeg)
        for field in ChatProtocol.fields + ["signature", "type"] {
            var bad = sealed
            bad[field] = "tampered"
            do {
                _ = try ChatProtocol.openPhoto(bad, signing: b, scope: scope)
                preconditionFailure("Accepted tampered photo \(field)")
            } catch {}
        }
        do {
            _ = try ChatProtocol.open(sealed, signing: b, scope: scope)
            preconditionFailure("Photo interpreted as text")
        } catch {}
        do {
            _ = try ChatProtocol.sealPhoto(jpeg, to: bob,
                bundle: ChatProtocol.keyBundle(b, scope: scope), signing: a, scope: scope)
            preconditionFailure("Photo sent to text-only device")
        } catch {}
        for invalid in [Data(), Data("not JPEG".utf8), Data(repeating: 1, count: ChatProtocol.maximumPhotoBytes + 1)] {
            precondition(ChatImage.image(invalid) == nil)
            do {
                _ = try ChatProtocol.sealPhoto(invalid, to: bob, bundle: bundle, signing: a, scope: scope)
                preconditionFailure("Accepted invalid photo")
            } catch {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MessageStore(directory: root)
        store.connect(signing: a, scope: scope, supported: true, trusted: { [bob: "Bob"] },
            send: { precondition($0["type"] != "chat-photo") }, transferPhoto: {
                if $0["type"] == "chat-photo" {
                    return ["type": "chat-stored", "scope": scope, "id": $0["id"]!, "to": bob]
                }
                return ["type": "chat-photo-empty"]
            })
        defer { store.disconnect() }
        store.receive(["type": "chat-ready", "push": "no"])
        precondition(!store.sendPhoto(jpeg, to: bob) && store.entries.isEmpty)
        store.receive(["type": "chat-ready", "photos": "1"])
        store.receive(["type": "chat-photo-ready"])
        store.receive(bundle)
        precondition(store.sendPhoto(jpeg, to: bob))
        try await wait { store.entries.first?.state == .queued }
        store.receive(try ChatProtocol.receipt(store.entries[0].envelope!, signing: b))
        let incoming = try ChatProtocol.sealPhoto(jpeg, to: alice,
            bundle: ChatProtocol.keyBundle(a, scope: scope, photos: true), signing: b, scope: scope)
        store.receive(incoming)
        store.receive(incoming)
        precondition(store.entries.count == 2 && store.unreadCount == 1)
        let restored = MessageStore(directory: root)
        restored.prepare(signing: a, scope: scope)
        precondition(restored.entries == store.entries && restored.entries[0].photo == jpeg)
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        let bytes = try Data(contentsOf: file)
        precondition(bytes.range(of: jpeg.prefix(64)) == nil, "Photo history must be encrypted")
        precondition(bytes.range(of: Data(jpeg.base64EncodedString().prefix(64).utf8)) == nil,
                     "JSON-encoded photo bytes must also be encrypted")
        store.markRead(bob)
        store.clearReadHistory(bob)
        store.receive(incoming)
        precondition(store.entries.isEmpty && store.unreadCount == 0)
    }
}
