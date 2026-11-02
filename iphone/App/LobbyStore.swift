import Combine
import CryptoKit
import Foundation
import Security

struct LobbyIdentity: Codable {
    var secret: Data
    var trusted: [String: String]

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Canddle") + ".lobby",
            kSecAttrAccount as String: "device-identity",
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load() throws -> LobbyIdentity {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            let value = Self(secret: Curve25519.Signing.PrivateKey().rawRepresentation, trusted: [:])
            try value.save()
            return value
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.save() // Migrate existing unlocked-only entries for locked call answering.
        return value
    }

    func save() throws {
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct LobbyCandidate: Identifiable {
    let exchange: LobbyExchange
    var confirmed = false
    var id: String { exchange.request.id }
}

@MainActor
final class LobbyStore: ObservableObject {
    @Published var name = "My iPhone"
    @Published private(set) var active = false
    @Published private(set) var online = false
    @Published private(set) var sending = false
    @Published private(set) var status = "Go online to receive call announcements while this app is open."
    @Published private(set) var offers: [LobbyOffer] = []
    @Published private(set) var ownOffer: LobbyOffer?
    @Published private(set) var candidates: [LobbyCandidate] = []
    @Published private(set) var joining: LobbyExchange?
    @Published private(set) var confirmed = false
    @Published private(set) var approving: String?
    @Published private(set) var trusted: [String: String] = [:]
    private var identity: LobbyIdentity?
    private var signing: Curve25519.Signing.PrivateKey?
    private var transport: Relay?
    private var task: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var invitation: CallInvitation?
    private var scope = ""
    private var sessionName = ""
    private var onJoin: ((String) -> Void)?
    private let loadIdentity: () throws -> LobbyIdentity
    private let saveIdentity: (LobbyIdentity) throws -> Void

    init(loadIdentity: @escaping () throws -> LobbyIdentity = LobbyIdentity.load,
         saveIdentity: @escaping (LobbyIdentity) throws -> Void = { try $0.save() }) {
        self.loadIdentity = loadIdentity
        self.saveIdentity = saveIdentity
    }

    var waiting: Bool { ownOffer != nil || joining != nil }

    func trustedName(_ key: String) -> String? { trusted[scope + "|" + key] }

    func connect(_ settings: RelaySettings, onJoin: @escaping (String) -> Void) {
        guard !active else { return }
        do {
            guard LobbyProtocol.nameValid(name) else {
                status = "Use a device name of 1-40 printable English characters."
                return
            }
            let saved = try loadIdentity()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: saved.secret)
            identity = saved
            signing = key
            trusted = saved.trusted
            scope = settings.url.absoluteString
            sessionName = name
            self.onJoin = onJoin
            active = true
            let id = UUID()
            generation = id
            let relay = Relay(settings)
            transport = relay
            status = "Connecting to call lobby..."
            task = Task {
                do {
                    try await relay.openLobby(identity: key, name: sessionName)
                    guard generation == id else { return }
                    online = true
                    status = "Online. Call announcements are visible to all connected lobby peers."
                    heartbeat = Task {
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(nanoseconds: 15_000_000_000)
                                try await relay.lobbySend(["type": "ping"])
                            }
                        } catch {
                            if generation == id { disconnect("Lobby connection ended. Go online again.") }
                        }
                    }
                    while !Task.isCancelled {
                        let message = try await relay.lobbyReceive()
                        guard generation == id else { return }
                        try receive(message)
                    }
                } catch {
                    if generation == id {
                        disconnect("Lobby connection ended. Check relay upgrade, token and TLS trust, then go online again.")
                    }
                }
            }
        } catch {
            status = "Could not load or save the device identity securely. Unlock your iPhone and retry."
        }
    }

    func disconnect(_ message: String = "Offline. No incoming call announcements.") {
        generation = UUID()
        transport?.stop()
        transport = nil
        task?.cancel()
        heartbeat?.cancel()
        action?.cancel()
        deadline?.cancel()
        task = nil
        heartbeat = nil
        action = nil
        deadline = nil
        signing = nil
        identity = nil
        onJoin = nil
        offers = []
        clearPending()
        active = false
        online = false
        sending = false
        status = message
    }

    private func clearPending() {
        deadline?.cancel()
        deadline = nil
        ephemeral = nil
        invitation = nil
        ownOffer = nil
        joining = nil
        candidates = []
        confirmed = false
        approving = nil
    }

    private func expirePending() {
        deadline?.cancel()
        let id = generation
        deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
                guard id == generation else { return }
                disconnect("Call request expired. Go online to try again.")
            } catch {}
        }
    }

    private func send(_ message: [String: String]) {
        guard online, !sending, let relay = transport else { return }
        let id = generation
        sending = true
        action = Task {
            do {
                try await relay.lobbySend(message)
                if generation == id { sending = false; action = nil }
            } catch {
                if generation == id { disconnect("Could not send the request. Go online to try again.") }
            }
        }
    }

    func announce() {
        guard online, !waiting, !sending, let signing else { return }
        do {
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let offer = try LobbyOffer.create(identity: signing, name: sessionName, ephemeral: ephemeral)
            invitation = try CallInvitation.generate()
            self.ephemeral = ephemeral
            ownOffer = offer
            candidates = []
            expirePending()
            status = "Call announced for two minutes. Approve one requester to start."
            send(offer.message)
        } catch {
            disconnect("Could not create a secure call.")
        }
    }

    func request(_ offer: LobbyOffer) {
        guard online, !waiting, !sending, let signing, offers.contains(where: { $0.id == offer.id }) else {
            return
        }
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let request = try LobbyRequest.create(offer: offer, identity: signing, name: sessionName, ephemeral: key)
            joining = try LobbyExchange(offer: offer, request: request, ephemeral: key, caller: false)
            confirmed = false
            expirePending()
            status = "Verify the caller, then confirm your request. The caller must approve."
            send(request.message)
        } catch { disconnect("The call announcement could not be authenticated.") }
    }

    private func remember(_ key: String, name: String) throws {
        guard var saved = identity else { throw VoiceError.peer }
        let id = scope + "|" + key
        if saved.trusted[id] != nil { return }
        guard saved.trusted.count < 100 else { throw VoiceError.packet }
        saved.trusted[id] = name
        try saveIdentity(saved)
        identity = saved
        trusted = saved.trusted
    }

    func forgetPeers() {
        guard !active else { return }
        do {
            var saved = try loadIdentity()
            saved.trusted = [:]
            try saveIdentity(saved)
            trusted = [:]
            status = "Verified peers forgotten. Compare security codes again next time."
        } catch { status = "Could not delete verified peers securely." }
    }

    func confirmCaller() {
        guard let joining, online, !confirmed, !sending else { return }
        do {
            try remember(joining.offer.identity, name: joining.offer.name)
            confirmed = true
            status = "Waiting for caller approval..."
            send([
                "type": "confirm", "call": joining.offer.id, "request": joining.request.id,
                "proof": joining.confirmation()
            ])
        } catch { status = "Could not save peer verification. No confirmation was sent." }
    }

    func approve(_ candidate: LobbyCandidate) {
        guard let offer = ownOffer, let invitation, online, !sending, approving == nil,
              let current = candidates.first(where: { $0.id == candidate.id }),
              current.confirmed else { return }
        do {
            let request = current.exchange.request
            let box = try current.exchange.seal(invitation)
            try remember(request.identity, name: request.name)
            approving = current.id
            status = "Sending the invitation encrypted for the approved peer..."
            send(["type": "approve", "call": offer.id, "request": current.id, "box": box])
        } catch { status = "Could not save verification or encrypt the invitation. Nothing was sent." }
    }

    func reject(_ candidate: LobbyCandidate) {
        guard let ownOffer, !sending, approving == nil else { return }
        send(["type": "reject", "call": ownOffer.id, "request": candidate.id])
        candidates.removeAll { $0.id == candidate.id }
    }

    func cancelRequest() {
        guard !sending, approving == nil else { return }
        if let ownOffer {
            send(["type": "cancel", "call": ownOffer.id])
        } else if let joining {
            send(["type": "withdraw", "call": joining.offer.id, "request": joining.request.id])
        }
        clearPending()
        status = "Call request canceled."
    }

    private func start(_ invitation: CallInvitation) {
        let callback = onJoin
        disconnect("Approved. Starting the encrypted call.")
        callback?(invitation.text)
    }

    private func receive(_ message: [String: String]) throws {
        switch message["type"] {
        case "pong":
            break
        case "offer":
            let offer = try LobbyOffer(message)
            if offer.identity == signing.map({ VoiceProtocol.base64($0.publicKey.rawRepresentation) }) { return }
            guard offers.count < 32, !offers.contains(where: { $0.id == offer.id }) else {
                throw VoiceError.packet
            }
            offers.append(offer)
            if !waiting { status = "Incoming call available. Request to join below." }
        case "request":
            guard let ownOffer, let ephemeral, approving == nil else { return }
            let request = try LobbyRequest(message, offer: ownOffer)
            guard candidates.count < 16, !candidates.contains(where: { $0.id == request.id }) else {
                throw VoiceError.packet
            }
            candidates.append(LobbyCandidate(exchange: try LobbyExchange(
                offer: ownOffer, request: request, ephemeral: ephemeral, caller: true
            )))
        case "confirm":
            guard message["call"] == ownOffer?.id,
                  let index = candidates.firstIndex(where: { $0.id == message["request"] }),
                  let proof = message["proof"] else { return }
            try candidates[index].exchange.verifyConfirmation(proof)
            candidates[index].confirmed = true
        case "approve":
            guard let joining, confirmed, message["call"] == joining.offer.id,
                  message["request"] == joining.request.id, let box = message["box"] else {
                throw VoiceError.peer
            }
            start(try joining.open(box))
        case "granted":
            guard let invitation, let approving, message["call"] == ownOffer?.id,
                  message["request"] == approving else { throw VoiceError.peer }
            start(invitation)
        case "closed":
            guard let call = message["call"] else { throw VoiceError.packet }
            offers.removeAll { $0.id == call }
            if call == ownOffer?.id || call == joining?.offer.id {
                clearPending()
                status = "Call announcement closed or expired."
            }
        case "removed":
            if message["call"] == ownOffer?.id {
                candidates.removeAll { $0.id == message["request"] }
                if approving == message["request"] {
                    approving = nil
                    status = "That peer is no longer available. Choose another request."
                }
            } else if message["call"] == joining?.offer.id, message["request"] == joining?.request.id {
                clearPending()
                status = "Join request declined or withdrawn."
            }
        default:
            throw VoiceError.packet
        }
    }
}
