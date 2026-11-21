import CryptoKit
import Foundation

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
        let incoming = try ChatProtocol.seal("Private reply", to: alice,
            bundle: ChatProtocol.keyBundle(a, scope: scope), signing: b, scope: scope)
        store.receive(incoming)
        store.receive(incoming)
        precondition(store.entries.count == 2 && store.unreadCount == 1)
        store.markRead(bob)
        precondition(store.unreadCount == 0)
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
        struct Input: Decodable { let address: String; let token: String; let enabled: Bool }
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
        for index in 0..<2 {
            let group = groups[index], store = stores[index]
            group.name = index == 0 ? "Alice" : "Bob"
            group.onMessagingReady = { key, scope, supported in
                store.connect(signing: key, scope: scope, supported: supported, trusted: {
                    [index == 0 ? bob : alice: index == 0 ? "Bob" : "Alice"]
                }, send: { try await group.sendMessageFrame($0, scope: scope) })
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
}
