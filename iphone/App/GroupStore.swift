import Combine
import CryptoKit
import Foundation

@MainActor
final class GroupStore: ObservableObject {
    struct LegacyCallRequest {
        let target: String?
        fileprivate let generation: UUID
    }

    @Published var name = "My iPhone"
    @Published var autoAcceptVerifiedDevices = false
    var webRTCAvailable = false
    @Published var preferWebRTC = false
    @Published private(set) var webRTCSupported = false
    private var qualitySupported = false
    private var qualityPathSupported = false
    private var trickleSupported = false
    private var recoverySupported = false
    private var resumeToken: String?
    private var connectionSettings: RelaySettings?
    @Published private(set) var reconnecting = false
    private var awaitingResumeState = false
    private var needsMediaRefresh = false
    private var recoveryWindow: UUID?
    private var recoveryDeadline: Task<Void, Never>?
    var onMediaSuspended: (() -> Void)?
    @Published private(set) var pendingLegacyCall: LegacyCallRequest?
    private var iceServers: [CallICEServer] = []
    private(set) var webRTCSignals: [WebRTCSignal] = []
    private var localWebRTCSignals: [String: WebRTCSignal] = [:]
    private(set) var webRTCCandidates: [WebRTCCandidate] = []
    private var incomingICE: [String: WebRTCCandidateStream] = [:]
    private var outgoingICE: [String: WebRTCCandidateStream] = [:]
    var onWebRTCSessionChanged: ((WebRTCSession?) -> Void)?
    var onWebRTCSignal: ((WebRTCSignal) -> Void)?
    var onWebRTCCandidate: ((WebRTCCandidate) -> Void)?
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
    @Published private(set) var profilesSupported = false
    @Published private(set) var profiles: [String: DeviceProfile] = [:]
    private let profileCache: MemberProfileCache
    private var profilePhoto = Data()
    private var profileRevision: UInt64 = 0
    private var profileTask: Task<Void, Never>?
    private var profileSentAt = Date.distantPast
    @Published private(set) var directCallsSupported = false
    @Published private(set) var presenceTruncated = false
    @Published private(set) var presence: [String: GroupPresence] = [:]
    @Published private(set) var knownNames: [String: String] = [:]
    private(set) var localIdentity = ""
    var onAudioReady: (() -> Void)?
    var onOutgoingCall: ((LobbyOffer) -> Void)?
    var onIncomingCall: ((LobbyOffer) -> Void)?
    var onIncomingHandled: ((String) -> Void)?
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
    var relayScope: String { scope }
    private var sessionName = ""
    private var roster: GroupRoster?
    private var proposed: GroupRoster?
    private var cipher: GroupCipher?
    private var mixer = GroupMixer()
    private var ignored = Set<String>()
    private var departed = Set<String>()
    private var autoStart = false
    private var startTarget: String?
    private var blockedAutomaticAdmissions = Set<String>()

    init(loadIdentity: @escaping () throws -> LobbyIdentity = LobbyIdentity.load,
         saveIdentity: @escaping (LobbyIdentity) throws -> Void = { try $0.save() },
         profileCache: MemberProfileCache = MemberProfileCache()) {
        self.loadIdentity = loadIdentity
        self.saveIdentity = saveIdentity
        self.profileCache = profileCache
    }

    var waiting: Bool { ownOffer != nil || joining != nil }
    var isCaller: Bool { ownOffer != nil }
    var isIndividual: Bool { (ownOffer ?? joining?.offer)?.target != nil }
    var usesWebRTC: Bool { (ownOffer ?? joining?.offer)?.usesWebRTC == true }
    var recoveringMedia: Bool { recoveryWindow != nil }
    var webRTCSession: WebRTCSession? {
        guard inCall, usesWebRTC, !recoveringMedia,
              let offer = ownOffer ?? joining?.offer, let roster else { return nil }
        return WebRTCSession(offer: offer, roster: roster, identity: ownIdentity, servers: iceServers,
                             trickle: trickleSupported, recovery: recoverySupported && resumeToken != nil)
    }
    var memberLimit: Int { isIndividual ? 2 : 6 }
    var approving: String? { proposed?.message["revision"] }
    var ownIdentity: String { signing.map { VoiceProtocol.base64($0.publicKey.rawRepresentation) } ?? "" }
    var visibleCandidates: [LobbyCandidate] { candidates.filter { !ignored.contains($0.id) } }
    func trustedName(_ key: String) -> String? { trusted[scope + "|" + key] }

    func callPhase(configured: Bool = true, audioBusy: Bool = false,
                   audioConnected: Bool = false, pairing: Bool = false) -> CallPhase {
        CallPhase.resolve(.init(configured: configured, online: online,
            relayConnecting: active && !online, pairing: pairing, audioBusy: audioBusy,
            audioConnected: audioConnected, admitted: inCall, recovering: recoveringMedia,
            calling: ownOffer != nil, joining: joining != nil, confirmed: confirmed,
            requests: visibleCandidates.count,
            confirmedRequests: visibleCandidates.filter(\.confirmed).count,
            approving: approving != nil))
    }

    func updateProfile(photo: Data, revision: UInt64) {
        guard DeviceProfile.validPhoto(photo), revision > profileRevision else { return }
        profilePhoto = photo
        profileRevision = revision
        publishProfile()
    }

    private func publishProfile() {
        guard online, profilesSupported, profileRevision > 0, profileTask == nil,
              let relay = transport, let signing else { return }
        let id = generation
        profileTask = Task {
            defer { if generation == id { profileTask = nil } }
            do {
                while generation == id {
                    let delay = max(0, 5 - Date().timeIntervalSince(profileSentAt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard generation == id else { return }
                    let profile = try DeviceProfile.create(
                        photo: profilePhoto, revision: profileRevision, signing: signing)
                    try await relay.groupSend(profile.message)
                    guard generation == id else { return }
                    profileSentAt = Date()
                    if profile.revision == profileRevision { return }
                }
            } catch {
                if generation == id && !recoverConnection(relay, error: error) {
                    disconnect("Photo sharing connection lost. Reconnect to retry.")
                }
            }
        }
    }

    var groupDirectory: [GroupPresence] {
        // Older caches and offline relay snapshots may have a photo but no remembered name.
        var names = profiles.mapValues { "Saved member " + LobbyProtocol.fingerprint($0.identity).prefix(8) }
        let prefix = scope + "|"
        for (key, value) in trusted where key.hasPrefix(prefix) {
            names[String(key.dropFirst(prefix.count))] = value
        }
        // Saved trust names are fallbacks, not overrides for current device names.
        names.merge(knownNames) { _, latest in latest }
        for member in presence.values { names[member.id] = member.name }
        if !localIdentity.isEmpty { names[localIdentity] = name }
        return names.map { key, value in
            let state = presence[key]?.state
                ?? (online && presenceReady && !presenceTruncated ? .disconnected : .unknown)
            return GroupPresence(id: key, name: value, state: state)
        }.sorted {
            if $0.id == localIdentity { return $1.id != localIdentity }
            if $1.id == localIdentity { return false }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
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

    func connect(_ settings: RelaySettings, startCall: Bool = false, target: String? = nil) {
        guard !active else { if startCall { announce(target: target) }; return }
        do {
            guard LobbyProtocol.nameValid(name) else {
                status = "Use a device name of 1-40 printable English characters."; return
            }
            let saved = try loadIdentity()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: saved.secret)
            signing = key
            if scope != settings.url.absoluteString {
                presence = [:]
                profiles = profileCache.load(scope: settings.url.absoluteString)
                knownNames = profileCache.loadNames(scope: settings.url.absoluteString)
                    .filter { profiles[$0.key] != nil }
            }
            localIdentity = VoiceProtocol.base64(key.publicKey.rawRepresentation)
            identity = saved
            trusted = saved.trusted
            scope = settings.url.absoluteString
            sessionName = name
            connectionSettings = settings
            autoStart = startCall
            startTarget = target
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
                    directCallsSupported = relay.supportsDirectCalls
                    if directCallsSupported {
                        try await relay.groupSend(["type": "direct-enable"])
                    }
                    webRTCSupported = relay.supportsWebRTC && webRTCAvailable
                    trickleSupported = webRTCSupported && relay.supportsTrickle
                    if webRTCSupported { try await relay.groupSend(["type": "rtc-enable"]) }
                    recoverySupported = trickleSupported && relay.supportsRecovery
                    if recoverySupported { try await relay.groupSend(["type": "recovery-enable"]) }
                    qualitySupported = webRTCSupported && relay.supportsQuality
                    qualityPathSupported = qualitySupported && relay.supportsQualityPath
                    presenceSupported = relay.supportsPresence
                    profilesSupported = relay.supportsProfiles
                    if profilesSupported { try await relay.groupSend(["type": "profile-subscribe"]) }
                    if presenceSupported {
                        try await relay.groupSend(["type": "presence-subscribe"])
                    }
                    if pushToken != nil {
                        try await relay.groupSend(["type": "push-capabilities"])
                    }
                    online = true
                    publishProfile()
                    status = "Online. Start a group call or call a member."
                    startHeartbeat(relay, id: id)
                    if autoStart {
                        autoStart = false
                        announce(target: startTarget)
                        startTarget = nil
                    }
                    try await read(relay, id: id)
                } catch {
                    if generation == id && !recoverConnection(relay, error: error) {
                        disconnect("Group connection or authentication failed. Check the upgraded relay, TLS and network.")
                    }
                }
            }
        } catch { status = "Could not load the device identity. Unlock the phone and retry." }
    }

    private func read(_ relay: Relay, id: UUID) async throws {
        while !Task.isCancelled {
            let incoming = try await relay.groupReceive(seconds: recoverySupported && inCall ? 15 : 45)
            guard generation == id else { return }
            switch incoming {
            case .data(let bytes):
                guard var current = cipher else { continue }
                let frame = try current.open(bytes)
                cipher = current
                if let (sender, frame) = frame { try mixer.push(frame, from: sender) }
            case .string(let text):
                guard text.utf8.count <= WebRTCSignal.maximumSize else { throw VoiceError.packet }
                let message = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
                guard message["type"] == "rtc-signal" || text.utf8.count <= 8192 else { throw VoiceError.packet }
                try receive(message)
            @unknown default: throw VoiceError.packet
            }
        }
    }

    private func startHeartbeat(_ relay: Relay, id: UUID) {
        heartbeat?.cancel()
        heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    guard generation == id else { return }
                    try await relay.groupSend(["type": "ping"])
                }
            } catch {
                if generation == id && !recoverConnection(relay, error: error) {
                    disconnect("Group connection lost.")
                }
            }
        }
    }

    private func beginRecoveryWindow() {
        guard recoveryWindow == nil else { return }
        let id = UUID()
        recoveryWindow = id
        recoveryDeadline = Task {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { return }
            if recoveryWindow == id { disconnect("Could not recover the call within 30 seconds.") }
        }
    }

    private func endRecoveryWindow() {
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        recoveryWindow = nil
        reconnecting = false
        awaitingResumeState = false
        needsMediaRefresh = false
    }

    /// Called by the system path monitor, not by periodic UI refresh.
    func networkChanged() {
        guard inCall, usesWebRTC, let transport else { return }
        if !reconnecting { _ = recoverConnection(transport, error: VoiceError.timeout, networkChange: true) }
    }

    @discardableResult
    private func recoverConnection(_ failed: Relay, error: Error, networkChange: Bool = false) -> Bool {
        guard transport === failed, inCall, usesWebRTC, recoverySupported,
              let token = resumeToken, let settings = connectionSettings, let signing,
              let call = (ownOffer ?? joining?.offer)?.id,
              networkChange || failed.canRecover(error) else { return false }
        let retry = reconnecting
        beginRecoveryWindow()
        reconnecting = true
        online = false
        awaitingResumeState = true
        offers = []
        status = "Network changed. Reconnecting the current call..."
        onMediaSuspended?()
        let id = UUID()
        generation = id
        // Mark the old connection recoverable before cancelling any socket wait.
        failed.stop(VoiceError.timeout, recoverable: true)
        profileTask?.cancel(); profileTask = nil
        task?.cancel()
        heartbeat?.cancel(); heartbeat = nil
        action?.cancel(); action = nil
        sending = false
        let relay = Relay(settings)
        transport = relay
        task = Task {
            do {
                if retry { try await Task.sleep(nanoseconds: 1_000_000_000) }
                guard generation == id else { return }
                try await relay.openLobby(identity: signing, name: sessionName, group: true,
                                          resume: (call, token))
                guard generation == id else { return }
                online = true
                startHeartbeat(relay, id: id)
                try await read(relay, id: id)
            } catch {
                if generation == id && !recoverConnection(relay, error: error) {
                    disconnect("The call could not be resumed securely or is no longer available.")
                }
            }
        }
        return true
    }

    /// Request a caller-signed fresh epoch instead of accepting unsigned ICE restarts.
    @discardableResult
    func recoverMedia() -> Bool {
        guard inCall, usesWebRTC, recoverySupported, resumeToken != nil,
              let roster, let relay = transport else { return false }
        if recoveryWindow != nil { return true }
        guard online else { return false }
        beginRecoveryWindow()
        onMediaSuspended?()
        status = "Restoring encrypted audio after a network change..."
        let id = generation
        Task {
            do {
                try await relay.groupSend(["type": "rtc-refresh", "call": roster.message["call"]!,
                    "revision": String(roster.revision), "epoch": roster.message["epoch"]!])
            } catch {
                if generation == id && !recoverConnection(relay, error: error) {
                    disconnect("Could not request authenticated media recovery.")
                }
            }
        }
        return true
    }

    private func processMediaRefresh() {
        guard needsMediaRefresh, online, !awaitingResumeState, !sending,
              proposed == nil, departed.isEmpty, let offer = ownOffer, let roster, let signing else { return }
        do {
            let next = try GroupRoster.create(offer: offer, revision: roster.revision + 1,
                                              members: members, signing: signing)
            needsMediaRefresh = false
            proposed = next
            send([next.message])
        } catch { disconnect("Could not renew the call's authenticated media epoch.") }
    }

    func disconnect(_ message: String = "Offline. Reconnects automatically on Calls.") {
        generation = UUID()
        transport?.stop(); transport = nil
        profileTask?.cancel(); profileTask = nil
        task?.cancel(); task = nil
        heartbeat?.cancel(); heartbeat = nil
        action?.cancel(); action = nil
        clearCall(message)
        signing = nil; identity = nil
        offers = []; active = false; online = false; sending = false
        presence = [:]; presenceReady = false; presenceSupported = false; presenceTruncated = false
        profilesSupported = false
        autoStart = false
        startTarget = nil; directCallsSupported = false
        webRTCSupported = false; qualitySupported = false; qualityPathSupported = false; iceServers = []
        trickleSupported = false
        recoverySupported = false; resumeToken = nil; connectionSettings = nil
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
        endRecoveryWindow()
        ownOffer = nil; joining = nil; confirmed = false
        pendingLegacyCall = nil
        members = []; candidates = []; ignored = []; departed = []
        blockedAutomaticAdmissions = []
        ephemeral = nil; roster = nil; proposed = nil; cipher = nil
        mixer.reset([])
        inCall = false
        resetWebRTCSignals()
        onWebRTCSessionChanged?(nil)
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
                processMediaRefresh()
                processAutomaticAdmissions()
            } catch {
                if generation == id && !recoverConnection(relay, error: error) {
                    disconnect("Could not send group action. Reconnecting on Calls.")
                }
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

    func announce(target: String? = nil) {
        announce(target: target, webRTC: preferWebRTC)
    }

    func dismissLegacyCallRequest() {
        pendingLegacyCall = nil
    }

    func confirmLegacyCall(_ request: LegacyCallRequest) {
        // The dialog can dismiss before its button action runs. Use its captured
        // request, but never carry a confirmation across relay reconnections.
        guard generation == request.generation else { return }
        pendingLegacyCall = nil
        announce(target: request.target, webRTC: false)
    }

    private func announce(target: String?, webRTC: Bool) {
        guard online, !waiting, !inCall, !sending, let signing else { return }
        guard target == nil || directCallsSupported else {
            status = "Upgrade the relay to make individual calls."; return
        }
        guard !webRTC || webRTCSupported else {
            pendingLegacyCall = LegacyCallRequest(target: target, generation: generation)
            status = "WebRTC is unavailable on this relay. Choose Start legacy call to continue."
            return
        }
        pendingLegacyCall = nil
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let offer = try LobbyOffer.create(identity: signing, name: sessionName, ephemeral: key,
                                              target: target, webRTC: webRTC)
            ephemeral = key; ownOffer = offer
            members = [GroupMember(message: offer.message)]
            status = target == nil
                ? "Group call announced. Accept join requests below. Waiting expires in two minutes."
                : "Calling the selected device. Waiting expires in two minutes."
            expirePending()
            send([offer.message])
            onOutgoingCall?(offer)
        } catch { disconnect("Could not create an authenticated call.") }
    }

    func request(_ offer: LobbyOffer) {
        guard online, !waiting, !inCall, !sending, let signing,
              !offer.usesWebRTC || webRTCSupported,
              offer.target == nil || offer.target == ownIdentity,
              offers.contains(where: { $0.id == offer.id }) else { return }
        onIncomingHandled?(offer.id)
        pendingLegacyCall = nil
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

    func decline(_ offer: LobbyOffer) {
        guard online, !sending, offer.target == ownIdentity,
              offers.contains(where: { $0.id == offer.id }) else { return }
        onIncomingHandled?(offer.id)
        send([["type": "direct-decline", "call": offer.id]])
        offers.removeAll { $0.id == offer.id }
        notification = nil
    }

    // A lock-screen decline can arrive before the push-triggered connection is ready.
    func disconnect(declining offer: LobbyOffer) {
        guard active, offer.target != nil else { disconnect("Call ended."); return }
        let id = generation
        sending = true
        action?.cancel()
        action = Task {
            let until = Date().addingTimeInterval(3)
            while generation == id && !online && Date() < until {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
            guard generation == id else { return }
            if online, offer.target == ownIdentity, let transport {
                try? await transport.groupSend(["type": "direct-decline", "call": offer.id])
            }
            if generation == id { disconnect("Call ended.") }
        }
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
              members.count < memberLimit, let current = candidates.first(where: { $0.id == candidate.id }),
              offer.target == nil || current.exchange.request.identity == offer.target,
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

    private func processAutomaticAdmissions() {
        guard let ownOffer, (autoAcceptVerifiedDevices || ownOffer.target != nil), online, !sending,
              proposed == nil, departed.isEmpty, members.count < memberLimit,
              let candidate = candidates.first(where: {
                  $0.confirmed && !ignored.contains($0.id)
                      && (ownOffer.target == nil || $0.exchange.request.identity == ownOffer.target)
                      && !blockedAutomaticAdmissions.contains($0.exchange.request.identity)
                      && trustedName($0.exchange.request.identity) != nil
              }) else { return }
        // Reuse the signed-roster path; presence and display names never authorize admission.
        approve(candidate)
    }

    func reject(_ candidate: LobbyCandidate) {
        guard let ownOffer, !sending, proposed == nil else { return }
        blockedAutomaticAdmissions.insert(candidate.exchange.request.identity)
        send([["type": "reject", "call": ownOffer.id, "request": candidate.id]])
        candidates.removeAll { $0.id == candidate.id }
    }

    func ignore(_ candidate: LobbyCandidate) {
        ignored.insert(candidate.id)
        blockedAutomaticAdmissions.insert(candidate.exchange.request.identity)
        status = "Request ignored. It will expire without joining."
    }

    func remove(_ member: GroupMember) {
        guard member.id != ownIdentity, let offer = ownOffer, let signing,
              !sending, proposed == nil else { return }
        if isIndividual { cancelRequest(); return }
        do {
            blockedAutomaticAdmissions.insert(member.id)
            let next = try GroupRoster.create(offer: offer, revision: (roster?.revision ?? 0) + 1,
                members: members.filter { $0.id != member.id && !departed.contains($0.id) }, signing: signing)
            proposed = next
            send([next.message])
        } catch { disconnect("Could not update group membership securely.") }
    }

    private func processDepartures() {
        guard let offer = ownOffer, let signing, !sending, proposed == nil, !departed.isEmpty else { return }
        if isIndividual { cancelRequest(); return }
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
            forgetMemberPhotos()
            status = "Verified peers forgotten. Compare codes next time."
        } catch { status = "Could not forget verified peers." }
    }

    func forgetMemberPhotos() {
        profiles = [:]
        profileCache.clear()
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

    private func resetWebRTCSignals() {
        webRTCSignals = []; localWebRTCSignals = [:]; webRTCCandidates = []
        incomingICE = [:]; outgoingICE = [:]
    }

    func sendWebRTC(sdp: String, kind: String, to: String, epoch: String) async throws {
        guard let session = webRTCSession, session.roster.message["epoch"] == epoch,
              let signing, let transport else { throw VoiceError.ended }
        let signal = try WebRTCSignal.create(sdp: sdp, kind: kind, to: to, session: session, signing: signing)
        guard localWebRTCSignals[to] == nil else { throw VoiceError.packet }
        localWebRTCSignals[to] = signal
        do { try await transport.groupSend(signal.message) }
        catch { if !recoverConnection(transport, error: error) { throw error } }
    }

    func sendWebRTCCandidate(candidate: String, mid: String, to: String, epoch: String) async throws {
        guard let session = webRTCSession, session.trickle, session.roster.message["epoch"] == epoch,
              let description = localWebRTCSignals[to],
              webRTCSignals.contains(where: { $0.identity == to && $0.supportsTrickle }),
              let signing, let transport else { throw VoiceError.ended }
        var stream = outgoingICE[to] ?? WebRTCCandidateStream()
        let update = try WebRTCCandidate.create(candidate: candidate, mid: mid, sequence: stream.sequence + 1,
            session: session, description: description, signing: signing)
        try stream.accept(update)
        outgoingICE[to] = stream
        do { try await transport.groupSend(update.message) }
        catch { if !recoverConnection(transport, error: error) { throw error } }
    }

    /// Best-effort, redacted media statistics for the relay operator. Older relays
    /// that do not advertise the capability never receive it.
    func sendQuality(_ links: [WebRTCQualityLink]) {
        // Older relays reject unknown fields, so path diagnostics need the capability.
        let links = qualityPathSupported ? links : links.map { $0.withoutPath() }
        guard qualitySupported, online, let session = webRTCSession, let transport,
              let message = try? WebRTCQualityLink.message(call: session.offer.id, links: links) else { return }
        Task { try? await transport.groupSend(message) }
    }

    private func receive(_ message: [String: String]) throws {
        switch message["type"] {
        case "profile":
            // Cosmetic data must never tear down a call or change identity trust.
            guard profilesSupported, let profile = try? DeviceProfile(message) else { return }
            if let previous = profiles[profile.identity], previous.revision >= profile.revision { return }
            guard profiles[profile.identity] != nil || profiles.count < 128 else { return }
            profiles[profile.identity] = profile
            profileCache.save(profiles, scope: scope, names: knownNames)
        case "recovery-ready":
            guard recoverySupported, Set(message.keys) == ["type", "token"],
                  let token = message["token"] else { throw VoiceError.packet }
            _ = try VoiceProtocol.decode(token, size: 32)
            guard resumeToken == nil || resumeToken == token else { throw VoiceError.peer }
            resumeToken = token
        case "resume-state":
            guard reconnecting, awaitingResumeState, let offer = ownOffer ?? joining?.offer,
                  let previous = roster else { throw VoiceError.peer }
            var signed = message
            signed["type"] = "roster"
            let next = try GroupRoster(signed, offer: offer)
            guard next.revision >= previous.revision else { throw VoiceError.order }
            if ownOffer != nil {
                guard next.message == previous.message || next.message == proposed?.message else {
                    throw VoiceError.peer
                }
            } else {
                guard confirmed, let joining,
                      next.members.first(where: { $0.id == ownIdentity })?.message == joining.request.message else {
                    throw VoiceError.peer
                }
            }
            // A fresh socket may have missed committed membership events. Accept
            // only the verified snapshot, then wait for a NEW epoch before audio.
            roster = next
            members = next.members
            proposed = nil
            candidates = []
            departed.formIntersection(Set(members.map(\.id)))
            awaitingResumeState = false
            resetWebRTCSignals()
        case "rtc-refresh":
            guard recoverySupported, let roster, ownOffer?.id == message["call"],
                  Set(message.keys) == ["type", "call", "revision"],
                  let revision = message["revision"].flatMap(UInt64.init) else { throw VoiceError.peer }
            if revision < roster.revision { return }
            guard revision == roster.revision else { throw VoiceError.order }
            needsMediaRefresh = true
            processMediaRefresh()
        case "rtc-config":
            guard webRTCSupported else { throw VoiceError.packet }
            iceServers = try CallICEServer.parse(message)
        case "rtc-signal":
            guard let session = webRTCSession else { return }
            if message["call"] == session.offer.id,
               let revision = message["revision"].flatMap(UInt64.init),
               revision < session.roster.revision { return }
            let signal = try WebRTCSignal(message, session: session)
            guard signal.recipient == ownIdentity,
                  !webRTCSignals.contains(where: { $0.identity == signal.identity }),
                  webRTCSignals.count < 5 else { throw VoiceError.peer }
            webRTCSignals.append(signal)
            onWebRTCSignal?(signal)
        case "rtc-candidate":
            guard let session = webRTCSession else { return }
            if message["call"] == session.offer.id,
               let revision = message["revision"].flatMap(UInt64.init),
               revision < session.roster.revision { return }
            guard let sender = message["identity"],
                  let description = webRTCSignals.first(where: { $0.identity == sender }),
                  localWebRTCSignals[sender]?.supportsTrickle == true else { throw VoiceError.peer }
            let update = try WebRTCCandidate(message, session: session, description: description)
            guard update.recipient == ownIdentity else { throw VoiceError.peer }
            var stream = incomingICE[sender] ?? WebRTCCandidateStream()
            try stream.accept(update)
            incomingICE[sender] = stream
            guard webRTCCandidates.count < 5 * (WebRTCCandidate.limit + 1) else { throw VoiceError.packet }
            webRTCCandidates.append(update)
            onWebRTCCandidate?(update)
        case "presence":
            guard presenceSupported else { throw VoiceError.packet }
            let snapshot = try GroupPresenceSnapshot(message)
            let updatedPresence = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
            if presence != updatedPresence { presence = updatedPresence }
            // Persist names beside signed photos so offline rows survive a process restart.
            var updatedNames = knownNames
            for member in snapshot.members {
                if updatedNames[member.id] != nil || updatedNames.count < 128 {
                    updatedNames[member.id] = member.name
                }
            }
            if knownNames != updatedNames {
                knownNames = updatedNames
                profileCache.save(profiles, scope: scope, names: knownNames)
            }
            if !presenceReady { presenceReady = true }
            if presenceTruncated != snapshot.truncated { presenceTruncated = snapshot.truncated }
        case "push-capabilities":
            pushAvailable = message["enabled"] == "yes"
            if pushAvailable, let pushToken, let transport {
                Task {
                    do {
                        try await transport.groupSend([
                            "type": "push-register", "token": pushToken,
                            "environment": pushEnvironment, "scope": scope
                        ].merging(webRTCSupported ? ["media": "webrtc"] : [:]) { _, new in new })
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
            guard !offer.usesWebRTC || webRTCSupported else { throw VoiceError.peer }
            guard offer.target == nil || (directCallsSupported && offer.target == ownIdentity) else {
                throw VoiceError.peer
            }
            guard offers.count < 32, !offers.contains(where: { $0.id == offer.id }) else { throw VoiceError.packet }
            offers.append(offer)
            onIncomingCall?(offer)
            if !waiting {
                notify(offer.target == nil
                       ? "Group call from \(offer.name). Tap Join group call below."
                       : "Individual call from \(offer.name). Tap Answer below.")
            }
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
            if offer.usesWebRTC {
                guard webRTCSupported, !iceServers.isEmpty else { throw VoiceError.peer }
                cipher = nil
            } else {
                cipher = try GroupCipher(roster: next, identity: ownIdentity, ephemeral: ephemeral)
            }
            let joinedNames = next.members.filter { nextMember in
                nextMember.id != ownIdentity && !members.contains { $0.id == nextMember.id }
            }.map { trustedName($0.id) ?? $0.name }
            let announceJoin = ownOffer != nil || roster != nil
            roster = next; proposed = nil
            endRecoveryWindow()
            members = next.members
            departed = departed.intersection(Set(members.map(\.id)))
            mixer.reset(members.filter { $0.id != ownIdentity }.map(\.id))
            candidates.removeAll { candidate in members.contains { $0.id == candidate.exchange.request.identity } }
            deadline?.cancel(); deadline = nil
            let first = !inCall
            inCall = true
            resetWebRTCSignals()
            onWebRTCSessionChanged?(webRTCSession)
            status = isIndividual ? "Encrypted individual call. Only the selected two devices can join."
                : "Encrypted group call. \(members.count) participants. Later peers may request to join."
            if announceJoin && !joinedNames.isEmpty {
                notify("\(joinedNames.joined(separator: ", ")) joined the call.")
            }
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
        processMediaRefresh()
        processAutomaticAdmissions()
    }
}
