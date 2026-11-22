import Combine
import CryptoKit
import Foundation

@MainActor
final class MessageStore: ObservableObject {
    enum Delivery: String, Codable { case pending, queued, delivered, failed }
    struct Entry: Codable, Identifiable {
        var id: String
        let peer: String
        let outgoing: Bool
        let text: String
        var date: Date
        var state: Delivery
        var unread: Bool
        var envelope: [String: String]?
    }
    private struct Saved: Codable {
        var entries: [Entry] = []
        var seen: [String: Date] = [:]
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var status = "Connect to your relay to enable private messages."
    @Published private(set) var online = false
    @Published private(set) var supported = false
    @Published private(set) var pushAvailable = false
    @Published private(set) var error: String?
    @Published var notificationError: String?
    @Published var selectedPeer: String?
    @Published var showInbox = false
    private(set) var scope = ""
    var notificationToken = ""
    var environment = "development"
    private var signing: Curve25519.Signing.PrivateKey?
    private var file: URL?
    private let directory: URL
    private var seen: [String: Date] = [:]
    private var bundles: [String: [String: String]] = [:]
    private var attempts: [String: Date] = [:]
    private var trusted: () -> [String: String] = { [:] }
    private var transmit: (([String: String]) async throws -> Void)?
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private var storageBlocked = false
    private var flushing = false
    private var flushRequested = false
    private var badgeSupported = false
    private var receipts: [String: [String: String]] = [:]
    var onUnreadChange: (() -> Void)?
    var missedCallCount: () -> Int = { 0 }
    var unreadCount: Int { entries.filter(\.unread).count }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Messages", isDirectory: true)
    }

    func prepare(signing: Curve25519.Signing.PrivateKey, scope: String) {
        let identity = VoiceProtocol.base64(signing.publicKey.rawRepresentation)
        let hash = SHA256.hash(data: Data((scope + "|" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(hash + ".sealed")
        guard self.file != file else { return }
        defer { onUnreadChange?() }
        disconnect()
        self.scope = scope
        self.signing = signing
        self.file = file
        selectedPeer = nil
        supported = false
        trusted = { [:] }
        entries = []; seen = [:]; bundles = [:]; attempts = [:]; receipts = [:]
        storageBlocked = false
        error = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 24_000_000 else { throw VoiceError.packet }
                let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
                let data = try AES.GCM.open(sealed, using: ChatProtocol.derive(signing,
                    scope: scope, purpose: "chat-storage"))
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.entries.count <= 1000, saved.seen.count <= 4096 else { throw VoiceError.packet }
                entries = saved.entries
                seen = saved.seen
            }
        } catch {
            storageBlocked = true
            self.error = "Message history could not be opened safely. Existing data was not overwritten."
        }
    }

    private func persist(_ next: [Entry], seen nextSeen: [String: Date]? = nil) throws {
        guard !storageBlocked, let signing, let file else { throw VoiceError.ended }
        let recent = (nextSeen ?? seen).filter { $0.value > Date().addingTimeInterval(-ChatProtocol.lifetime) }
        guard next.count <= 1000, recent.count <= 4096 else { throw VoiceError.packet }
        let data = try JSONEncoder().encode(Saved(entries: next, seen: recent))
        let sealed = try AES.GCM.seal(data, using: ChatProtocol.derive(signing,
            scope: scope, purpose: "chat-storage")).combined!
        #if os(iOS)
        try sealed.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try sealed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
        let previousUnread = unreadCount
        if entries != next { entries = next }
        seen = recent
        if unreadCount != previousUnread { onUnreadChange?() }
    }

    func connect(signing: Curve25519.Signing.PrivateKey, scope: String, supported: Bool,
                 trusted: @escaping () -> [String: String],
                 send: @escaping ([String: String]) async throws -> Void) {
        prepare(signing: signing, scope: scope)
        disconnect()
        self.supported = supported
        self.trusted = trusted
        guard supported, !storageBlocked else {
            status = "Private messages require an updated relay with message storage enabled."
            return
        }
        transmit = send
        let id = generation
        polling = Task { [weak self] in
            guard let self, generation == id, !Task.isCancelled else { return }
            do {
                try await send(ChatProtocol.keyBundle(signing, scope: scope))
                while !Task.isCancelled, generation == id {
                    await flush()
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                }
            } catch {
                if generation == id { online = false; status = "Messages paused. Reconnect to retry." }
            }
        }
    }

    func disconnect() {
        generation = UUID()
        polling?.cancel(); polling = nil
        transmit = nil
        online = false
        badgeSupported = false
        flushing = false
        flushRequested = false
        status = "Offline. Pending messages will retry when connected."
    }

    func deactivate() {
        disconnect()
        showInbox = false
        selectedPeer = nil
        scope = ""
        file = nil
        signing = nil
        trusted = { [:] }
        supported = false
        pushAvailable = false
        entries = []; seen = [:]; bundles = [:]; attempts = [:]; receipts = [:]
        error = nil
        onUnreadChange?()
    }

    func synchronizeBadge() {
        guard transmit != nil else { return }
        Task { await flush() }
    }

    func send(_ text: String, to peer: String) {
        guard trusted()[peer] != nil, supported, !storageBlocked,
              (1...4096).contains(text.utf8.count),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Verify this device first; messages must contain 1-4096 UTF-8 bytes."
            return
        }
        do {
            try persist(entries + [Entry(id: LobbyProtocol.randomID(), peer: peer, outgoing: true,
                text: text, date: Date(), state: .pending, unread: false)])
            error = nil
            Task { await flush() }
        } catch { self.error = "Could not save the message. Clear read history if storage is full." }
    }

    func retry(_ entry: Entry) {
        guard entry.outgoing, entry.state == .failed, trusted()[entry.peer] != nil else { return }
        do {
            var next = entries
            guard let index = next.firstIndex(where: { $0.id == entry.id && $0.peer == entry.peer }) else { return }
            if next[index].date < Date().addingTimeInterval(-ChatProtocol.lifetime + 60) {
                next[index].id = LobbyProtocol.randomID()
                next[index].date = Date()
                next[index].envelope = nil
            }
            next[index].state = .pending
            try persist(next)
            error = nil
            attempts[entry.id] = nil
            Task { await flush() }
        } catch { self.error = "Could not save retry." }
    }

    func markRead(_ peer: String) {
        var next = entries
        for index in next.indices where next[index].peer == peer { next[index].unread = false }
        guard next != entries else { return }
        do {
            try persist(next)
            synchronizeBadge()
        } catch { self.error = "Could not save read status." }
    }

    func clearReadHistory(_ peer: String) {
        do {
            try persist(entries.filter {
                $0.peer != peer || $0.unread || ($0.outgoing && [.pending, .queued].contains($0.state))
            })
        } catch { self.error = "Could not clear read history." }
    }

    func flush() async {
        guard let transmit, let signing else { return }
        guard !flushing else { flushRequested = true; return }
        flushing = true
        let id = generation
        defer {
            if id == generation {
                flushing = false
                if flushRequested {
                    flushRequested = false
                    Task { await flush() }
                }
            }
        }
        do {
            // Snapshot receipts and count before awaiting: newer arrivals stay relay-pending.
            let batchKeys = Array(receipts.keys.sorted().prefix(32))
            let batch = batchKeys.compactMap { receipts[$0] }
            let remaining = Set(receipts.keys).subtracting(batchKeys)
            let unacknowledgedUnread = entries.filter {
                $0.unread && remaining.contains($0.peer + "|" + $0.id)
            }.count
            let count = max(0, missedCallCount()) + unreadCount - unacknowledgedUnread
            if badgeSupported {
                let encoded = String(data: try JSONEncoder().encode(batch), encoding: .utf8)!
                try await transmit(["type": "chat-badge", "count": String(count), "receipts": encoded])
            } else {
                for receipt in batch {
                    guard generation == id else { return }
                    try await transmit(receipt)
                }
            }
            guard generation == id else { return }
            for (key, receipt) in zip(batchKeys, batch) where receipts[key] == receipt {
                receipts[key] = nil
            }
            if !receipts.isEmpty { flushRequested = true }
            let contacts = trusted()
            let allowed = String(data: try JSONEncoder().encode(Array(contacts.keys.sorted().prefix(128))), encoding: .utf8)!
            try await transmit(["type": "chat-allow", "identities": allowed])
            guard generation == id else { return }
            try await transmit(["type": "chat-push", "token": notificationToken, "environment": environment])
            guard generation == id else { return }
            try await transmit(["type": "chat-pull"])
            guard generation == id else { return }
            let pending = entries.filter { $0.outgoing && [.pending, .queued].contains($0.state) }
                .sorted { (attempts[$0.id] ?? .distantPast) < (attempts[$1.id] ?? .distantPast) }
            for entry in pending.prefix(5) {
                guard generation == id, let index = entries.firstIndex(where: { $0.id == entry.id && $0.outgoing }) else { return }
                var next = entries
                if trusted()[entry.peer] == nil || entry.date < Date().addingTimeInterval(-ChatProtocol.lifetime + 60) {
                    next[index].state = .failed
                    try persist(next)
                    continue
                }
                attempts[entry.id] = Date()
                if next[index].envelope == nil {
                    guard let bundle = bundles[entry.peer] else {
                        try await transmit(["type": "chat-key-get", "to": entry.peer])
                        continue
                    }
                    next[index].envelope = try ChatProtocol.seal(entry.text, to: entry.peer, bundle: bundle,
                        signing: signing, scope: scope, now: entry.date, id: entry.id)
                    try persist(next) // Durable ciphertext/ID before sending; retries reuse it.
                }
                try await transmit(next[index].envelope!)
            }
        } catch {
            if generation == id { self.error = "Messages could not sync. Saved pending messages will retry." }
        }
    }

    func receive(_ message: [String: String]) {
        guard let signing, transmit != nil else { return }
        do {
            switch message["type"] {
            case "chat-ready":
                online = true
                pushAvailable = message["push"] == "yes"
                badgeSupported = message["badges"] == "1"
                status = "Private text messages are end-to-end encrypted."
                synchronizeBadge()
            case "chat-key":
                guard let peer = message["identity"], trusted()[peer] != nil else { return }
                _ = try ChatProtocol.verifyBundle(message, identity: peer, scope: scope)
                bundles[peer] = message
                status = "Private text messages are end-to-end encrypted."
                Task { await flush() }
            case "chat-send":
                guard let peer = message["from"], trusted()[peer] != nil else { return }
                let text = try ChatProtocol.open(message, signing: signing, scope: scope)
                let key = peer + "|" + message["id"]!
                if seen[key] == nil {
                    var nextSeen = seen
                    nextSeen[key] = Date()
                    let entry = Entry(id: message["id"]!, peer: peer, outgoing: false, text: text,
                        date: Date(timeIntervalSince1970: Double(message["created"]!)!),
                        state: .delivered, unread: selectedPeer != peer)
                    try persist(entries + [entry], seen: nextSeen)
                }
                let receipt = try ChatProtocol.receipt(message, signing: signing)
                receipts[key] = receipt
                Task { await flush() }
            case "chat-stored", "chat-receipt", "chat-error":
                guard let index = entries.firstIndex(where: {
                    $0.outgoing && $0.id == message["id"] && $0.peer == message["to"]
                }), let envelope = entries[index].envelope else { return }
                var next = entries
                if message["type"] == "chat-receipt" {
                    try ChatProtocol.verifyReceipt(message, message: envelope)
                    next[index].state = .delivered
                } else if next[index].state != .delivered {
                    if message["type"] == "chat-stored" {
                        guard message["scope"] == scope else { return }
                        next[index].state = .queued
                    } else {
                        next[index].state = .failed
                        error = "Message rejected. Check verification, clock, and recipient availability, then retry."
                    }
                }
                try persist(next)
            case "chat-unavailable":
                status = "Waiting for the recipient to enable messaging and verify your device."
            default: break
            }
        } catch {
            self.error = "A message could not be verified or saved. No delivery receipt was sent."
        }
    }
}

extension MessageStore.Entry: Equatable {}
