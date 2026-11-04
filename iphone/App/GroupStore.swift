import Combine
import CryptoKit
import Foundation

@MainActor
final class GroupStore: ObservableObject {
    @Published var name = "My iPhone"
    @Published private(set) var active = false
    @Published private(set) var online = false
    @Published private(set) var sending = false
    @Published private(set) var status = "Connects automatically once your relay is configured."
    @Published private(set) var offers: [LobbyOffer] = []
    @Published private(set) var ownOffer: LobbyOffer?
    @Published private(set) var candidates: [LobbyCandidate] = []
    @Published private(set) var joining: LobbyExchange?
    @Published private(set) var confirmed = false
    @Published private(set) var members: [GroupMember] = []
    @Published private(set) var inCall = false
    @Published private(set) var trusted: [String: String] = [:]
    @Published private(set) var notification: String?
    @Published private(set) var notificationID = UUID()
    @Published private(set) var presenceReady = false
    @Published private(set) var presenceSupported = false
    @Published private(set) var presenceTruncated = false
    @Published private(set) var presence: [String: GroupPresence] = [:]
    @Published private(set) var knownNames: [String: String] = [:]
    private(set) var localIdentity = ""
    var onAudioReady: (() -> Void)?
    var onAudioEnded: ((String) -> Void)?
    var onCallClosed: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var pushToken: String?
    var pushEnvironment = "development"
    @Published private(set) var pushStatus = "Background ringing requires Apple push provisioning."
    private var pushAvailable = false
    private let loadIdentity: () throws -> LobbyIdentity
    private let saveIdentity: (LobbyIdentity) throws -> Void
    private var identity: LobbyIdentity?
    private var signing: Curve25519.Signing.PrivateKey?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var transport: Relay?
    private var task: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var scope = ""
    private var sessionName = ""
    private var roster: GroupRoster?
    private var proposed: GroupRoster?
    private var cipher: GroupCipher?
    private var mixer = GroupMixer()
    private var ignored = Set<String>()
    private var departed = Set<String>()
    private var autoStart = false

    init(loadIdentity: @escaping () throws -> LobbyIdentity = LobbyIdentity.load,
         saveIdentity: @escaping (LobbyIdentity) throws -> Void = { try $0.save() }) {
        self.loadIdentity = loadIdentity
        self.saveIdentity = saveIdentity
    }

    var waiting: Bool { ownOffer != nil || joining != nil }
    var isCaller: Bool { ownOffer != nil }
    var approving: String? { proposed?.message["revision"] }
    var ownIdentity: String { signing.map { VoiceProtocol.base64($0.publicKey.rawRepresentation) } ?? "" }
    var visibleCandidates: [LobbyCandidate] { candidates.filter { !ignored.contains($0.id) } }
    func trustedName(_ key: String) -> String? { trusted[scope + "|" + key] }

    var groupDirectory: [GroupPresence] {
        var names = knownNames
        for member in presence.values { names[member.id] = member.name }
        let prefix = scope + "|"
        for (key, value) in trusted where key.hasPrefix(prefix) {
            names[String(key.dropFirst(prefix.count))] = value
        }
        if !localIdentity.isEmpty { names[localIdentity] = name }
        return names.map { key, value in
            let state = presence[key]?.state
                ?? (online && presenceReady && !presenceTruncated ? .disconnected : .unknown)
            return GroupPresence(id: key, name: value, state: state)
        }.sorted {
            if $0.id == localIdentity { return $1.id != localIdentity }
            if $1.id == localIdentity { return false }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    @discardableResult
    func rename(_ value: String) -> Bool {
        guard !waiting, !inCall, LobbyProtocol.nameValid(value),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard name != value else { return true }
        // Registration signs the name, so an idle connection must be replaced.
        if active { disconnect("Device name saved. Return to Calls to reconnect.") }
        name = value
        return true
    }

    func connect(_ settings: RelaySettings, startCall: Bool = false) {
        guard !active else { if startCall { announce() }; return }
        do {
            guard LobbyProtocol.nameValid(name) else {
                status = "Use a device name of 1-40 printable English characters."; return
            }
            let saved = try loadIdentity()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: saved.secret)
            signing = key
            if scope != settings.url.absoluteString {
                knownNames = [:]
                presence = [:]
            }
            localIdentity = VoiceProtocol.base64(key.publicKey.rawRepresentation)
            identity = saved
            trusted = saved.trusted
            scope = settings.url.absoluteString
            sessionName = name
            autoStart = startCall
            let relay = Relay(settings)
            transport = relay
            active = true
            status = "Connecting to relay group..."
            let id = UUID()
            generation = id
            task = Task {
                do {
                    try await relay.openLobby(identity: key, name: sessionName, group: true)
                    guard generation == id else { return }
                    online = true
                    presenceSupported = relay.supportsPresence
                    if presenceSupported {
                        try await relay.groupSend(["type": "presence-subscribe"])
                    }
                    status = "Online. Start a call or join an announced call."
                    if pushToken != nil {
                        try await relay.groupSend(["type": "push-capabilities"])
                    }
                    heartbeat = Task {
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(nanoseconds: 15_000_000_000)
                                try await relay.groupSend(["type": "ping"])
                            }
                        } catch {
                            if generation == id { disconnect("Group connection lost. Reconnecting on Calls.") }
                        }
                    }
                    if autoStart { autoStart = false; announce() }
                    while !Task.isCancelled {
                        let incoming = try await relay.groupReceive()
                        guard generation == id else { return }
                        switch incoming {
                        case .data(let bytes):
                            guard var current = cipher else { continue }
                            let frame = try current.open(bytes)
                            cipher = current
                            if let (sender, frame) = frame { try mixer.push(frame, from: sender) }
                        case .string(let text):
                            guard text.utf8.count <= 8192 else { throw VoiceError.packet }
                            try receive(JSONDecoder().decode([String: String].self, from: Data(text.utf8)))
                        @unknown default: throw VoiceError.packet
                        }
                    }
                } catch {
                    if generation == id {
                        disconnect("Group connection or authentication failed. Check the upgraded relay, TLS and network.")
                    }
                }
            }
        } catch { status = "Could not load the device identity. Unlock the phone and retry." }
    }

    func disconnect(_ message: String = "Offline. Reconnects automatically on Calls.") {
        generation = UUID()
        transport?.stop(); transport = nil
        task?.cancel(); task = nil
        heartbeat?.cancel(); heartbeat = nil
        action?.cancel(); action = nil
        clearCall(message)
        signing = nil; identity = nil
        offers = []; active = false; online = false; sending = false
        presence = [:]; presenceReady = false; presenceSupported = false; presenceTruncated = false
        autoStart = false
        status = message
        pushAvailable = false
        onDisconnected?()
    }

    func updatePushToken(_ token: String?) {
        pushToken = token
        guard online, let transport else { return }
        Task {
            do {
                if token == nil {
                    try await transport.groupSend(["type": "push-unregister"])
                } else {
                    try await transport.groupSend(["type": "push-capabilities"])
                }
            } catch { pushStatus = "Push registration failed. Reconnect to retry." }
        }
    }

    private func clearCall(_ message: String) {
        let hadAudio = inCall
        let endedCall = ownOffer?.id ?? joining?.offer.id
        deadline?.cancel(); deadline = nil
        ownOffer = nil; joining = nil; confirmed = false
        members = []; candidates = []; ignored = []; departed = []
        ephemeral = nil; roster = nil; proposed = nil; cipher = nil
        mixer.reset([])
        inCall = false
        notification = nil
        status = message
        if hadAudio { onAudioEnded?(message) }
        if let endedCall { onCallClosed?(endedCall) }
    }

    private func notify(_ text: String) {
        notification = text
        notificationID = UUID()
    }

    func dismissNotification() { notification = nil }

    private func send(_ messages: [[String: String]]) {
        guard online, !sending, let relay = transport else { return }
        sending = true
        let id = generation
        action = Task {
            do {
                for message in messages { try await relay.groupSend(message) }
                guard generation == id else { return }
                sending = false; action = nil
                processDepartures()
            } catch {
                if generation == id { disconnect("Could not send group action. Reconnecting on Calls.") }
            }
        }
    }

    private func expirePending() {
        deadline?.cancel()
        let id = generation
        deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
                if generation == id && !inCall { disconnect("Call request expired. Reconnecting on Calls.") }
            } catch {}
        }
    }

    func announce() {
        guard online, !waiting, !inCall, !sending, let signing else { return }
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let offer = try LobbyOffer.create(identity: signing, name: sessionName, ephemeral: key)
            ephemeral = key; ownOffer = offer
            members = [GroupMember(message: offer.message)]
            status = "Call announced. Accept join requests below. Waiting expires in two minutes."
            expirePending()
            send([offer.message])
        } catch { disconnect("Could not create an authenticated call.") }
    }

    func request(_ offer: LobbyOffer) {
        guard online, !waiting, !inCall, !sending, let signing,
              offers.contains(where: { $0.id == offer.id }) else { return }
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let request = try LobbyRequest.create(offer: offer, identity: signing, name: sessionName, ephemeral: key)
            let exchange = try LobbyExchange(offer: offer, request: request, ephemeral: key, caller: false)
            ephemeral = key; joining = exchange
            confirmed = trustedName(offer.identity) != nil
            expirePending()
            notification = nil
            if confirmed {
                status = "Join requested. Waiting for caller to accept."
                send([request.message, confirmation(exchange)])
            } else {
                status = "First call with this device: compare the code once, then confirm."
                send([request.message])
            }
        } catch { disconnect("Call announcement could not be authenticated.") }
    }

    private func confirmation(_ exchange: LobbyExchange) -> [String: String] {
        ["type": "confirm", "call": exchange.offer.id, "request": exchange.request.id,
         "proof": exchange.confirmation()]
    }

    private func remember(_ key: String, name: String) throws {
        guard var saved = identity else { throw VoiceError.peer }
        let id = scope + "|" + key
        if saved.trusted[id] != nil { return }
        guard saved.trusted.count < 100 else { throw VoiceError.packet }
        saved.trusted[id] = name
        try saveIdentity(saved)
        identity = saved; trusted = saved.trusted
    }

    func confirmCaller() {
        guard let joining, !confirmed, !sending else { return }
        do {
            try remember(joining.offer.identity, name: joining.offer.name)
            confirmed = true
            status = "Join requested. Waiting for caller to accept."
            send([confirmation(joining)])
        } catch { status = "Could not save verification. No confirmation sent." }
    }

    func approve(_ candidate: LobbyCandidate) {
        guard let offer = ownOffer, let signing, !sending, proposed == nil,
              members.count < 6, let current = candidates.first(where: { $0.id == candidate.id }),
              current.confirmed else { return }
        do {
            try remember(current.exchange.request.identity, name: current.exchange.request.name)
            let updated = members.filter { !departed.contains($0.id) }
                + [GroupMember(message: current.exchange.request.message)]
            let next = try GroupRoster.create(offer: offer, revision: (roster?.revision ?? 0) + 1,
                                              members: updated, signing: signing)
            proposed = next
            status = "Accepting participant and updating encrypted links..."
            send([next.message])
        } catch { status = "Could not save verification or authorize membership. Nothing sent." }
    }

    func reject(_ candidate: LobbyCandidate) {
        guard let ownOffer, !sending, proposed == nil else { return }
        send([["type": "reject", "call": ownOffer.id, "request": candidate.id]])
        candidates.removeAll { $0.id == candidate.id }
    }

    func ignore(_ candidate: LobbyCandidate) {
        ignored.insert(candidate.id)
        status = "Request ignored. It will expire without joining."
    }

    func remove(_ member: GroupMember) {
        guard member.id != ownIdentity, let offer = ownOffer, let signing,
              !sending, proposed == nil else { return }
        do {
            let next = try GroupRoster.create(offer: offer, revision: (roster?.revision ?? 0) + 1,
                members: members.filter { $0.id != member.id && !departed.contains($0.id) }, signing: signing)
            proposed = next
            send([next.message])
        } catch { disconnect("Could not update group membership securely.") }
    }

    private func processDepartures() {
        guard let offer = ownOffer, let signing, !sending, proposed == nil, !departed.isEmpty else { return }
        do {
            let next = try GroupRoster.create(offer: offer, revision: (roster?.revision ?? 0) + 1,
                members: members.filter { !departed.contains($0.id) }, signing: signing)
            proposed = next
            send([next.message])
        } catch { disconnect("Could not remove a disconnected participant securely.") }
    }

    func cancelRequest() {
        guard !sending, proposed == nil else { return }
        if let ownOffer {
            send([["type": "cancel", "call": ownOffer.id]])
        } else if let joining {
            send([["type": inCall ? "leave" : "withdraw", "call": joining.offer.id]
                .merging(inCall ? [:] : ["request": joining.request.id]) { _, new in new }])
        }
        clearCall("You left the call.")
    }

    func forgetPeers() {
        guard !active else { return }
        do {
            var saved = try loadIdentity()
            saved.trusted = [:]
            try saveIdentity(saved)
            trusted = [:]
            status = "Verified peers forgotten. Compare codes next time."
        } catch { status = "Could not forget verified peers." }
    }

    func transmit(_ frame: Data) async throws {
        guard inCall, let relay = transport, let revision = cipher?.revision else { return }
        for member in members where member.id != ownIdentity {
            // A membership event may arrive while a send is suspended. Do not
            // overwrite the new epoch's counters with the old local cipher.
            guard var current = cipher, current.revision == revision else { return }
            let packet = try current.seal(frame, to: member.id)
            cipher = current
            try await relay.groupMedia(packet)
        }
    }

    func mixedFrame() -> Data { mixer.mix() }

    private func receive(_ message: [String: String]) throws {
        switch message["type"] {
        case "presence":
            guard presenceSupported else { throw VoiceError.packet }
            let snapshot = try GroupPresenceSnapshot(message)
            presence = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
            // Remember a bounded set for this relay during this app session only.
            for member in snapshot.members {
                if knownNames[member.id] != nil || knownNames.count < 128 {
                    knownNames[member.id] = member.name
                }
            }
            presenceReady = true
            presenceTruncated = snapshot.truncated
        case "push-capabilities":
            pushAvailable = message["enabled"] == "yes"
            if pushAvailable, let pushToken, let transport {
                Task {
                    do {
                        try await transport.groupSend([
                            "type": "push-register", "token": pushToken,
                            "environment": pushEnvironment, "scope": scope
                        ])
                    } catch { pushStatus = "Push registration failed. Reconnect to retry." }
                }
            } else { pushStatus = "This relay has not enabled background ringing." }
        case "push-registered":
            pushStatus = "Background ringing registered with this relay."
        case "push-unregistered":
            pushStatus = "Background ringing registration removed."
        case "pong": break
        case "offer":
            let offer = try LobbyOffer(message)
            if offer.identity == ownIdentity { return }
            guard offers.count < 32, !offers.contains(where: { $0.id == offer.id }) else { throw VoiceError.packet }
            offers.append(offer)
            if !waiting { notify("Incoming call from \(offer.name). Tap Join call below.") }
        case "request":
            guard let offer = ownOffer, let ephemeral else { throw VoiceError.peer }
            let request = try LobbyRequest(message, offer: offer)
            guard candidates.count < 16, !candidates.contains(where: { $0.id == request.id }) else {
                throw VoiceError.packet
            }
            candidates.append(LobbyCandidate(exchange: try LobbyExchange(
                offer: offer, request: request, ephemeral: ephemeral, caller: true)))
            notify("\(request.name) wants to join your call.")
        case "confirm":
            guard message["call"] == ownOffer?.id,
                  let index = candidates.firstIndex(where: { $0.id == message["request"] }),
                  let proof = message["proof"] else { return }
            try candidates[index].exchange.verifyConfirmation(proof)
            candidates[index].confirmed = true
        case "roster":
            guard let offer = ownOffer ?? joining?.offer, let ephemeral else { return }
            let next = try GroupRoster(message, offer: offer)
            guard next.revision > (roster?.revision ?? 0) else { throw VoiceError.order }
            if let previous = roster {
                guard next.revision == previous.revision + 1 else { throw VoiceError.order }
            }
            if ownOffer != nil {
                guard next.message == proposed?.message else { throw VoiceError.peer }
            } else {
                guard confirmed, let joining else { throw VoiceError.peer }
                if let own = next.members.first(where: { $0.id == ownIdentity }) {
                    guard own.message == joining.request.message else { throw VoiceError.peer }
                } else {
                    clearCall("The caller removed you from the call."); return
                }
            }
            cipher = try GroupCipher(roster: next, identity: ownIdentity, ephemeral: ephemeral)
            roster = next; proposed = nil
            members = next.members
            departed = departed.intersection(Set(members.map(\.id)))
            mixer.reset(members.filter { $0.id != ownIdentity }.map(\.id))
            candidates.removeAll { candidate in members.contains { $0.id == candidate.exchange.request.identity } }
            deadline?.cancel(); deadline = nil
            let first = !inCall
            inCall = true
            status = "Encrypted group call. \(members.count) participants. Later peers may request to join."
            if first { onAudioReady?() }
            processDepartures()
        case "departed":
            guard message["call"] == ownOffer?.id, let peer = message["identity"] else { return }
            departed.insert(peer)
            processDepartures()
        case "roster-retry":
            guard message["call"] == ownOffer?.id,
                  message["revision"] == proposed?.message["revision"],
                  let peer = message["identity"] else { throw VoiceError.peer }
            proposed = nil
            candidates.removeAll { $0.exchange.request.identity == peer }
            if members.contains(where: { $0.id == peer }) { departed.insert(peer) }
            status = "Membership changed before acceptance. Unavailable requests were removed."
            processDepartures()
        case "removed":
            if message["call"] == ownOffer?.id {
                candidates.removeAll { $0.id == message["request"] }
            } else if message["call"] == joining?.offer.id, message["request"] == joining?.request.id, !inCall {
                clearCall("Join request rejected, withdrawn or expired.")
            }
        case "closed":
            guard let call = message["call"] else { throw VoiceError.packet }
            onCallClosed?(call)
            offers.removeAll { $0.id == call }
            if call == ownOffer?.id || call == joining?.offer.id {
                clearCall("Call ended or expired.")
            }
        default: throw VoiceError.packet
        }
    }
}
