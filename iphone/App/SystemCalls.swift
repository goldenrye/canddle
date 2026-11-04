import AVFoundation
import CallKit
import CryptoKit
import PushKit
import UIKit

/// Created at process launch, including launches caused by a VoIP push.
@MainActor
final class CallAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CallStore.shared.systemCalls.register()
        return true
    }
}

@MainActor
final class SystemCalls: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
    private weak var owner: CallStore?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var uuid: UUID?
    private var offer: LobbyOffer?
    private var callID: String?
    private var answer: CXAnswerCallAction?
    private var deadline: Task<Void, Never>?
    private var joining: Task<Void, Never>?
    private var audioActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var seen: [String: Date] = [:]
    var hasCall: Bool { uuid != nil }

    init(owner: CallStore) {
        self.owner = owner
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func register() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        self.registry = registry
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials,
                      for type: PKPushType) {
        guard type == .voIP, let owner else { return }
        owner.lobby.pushEnvironment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment")
            as? String ?? "development"
        owner.lobby.updatePushToken(credentials.token.map { String(format: "%02x", $0) }.joined())
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { owner?.lobby.updatePushToken(nil) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        // Every VoIP push is reported before network work, even stale or malformed ones.
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "canddle")
        update.localizedCallerName = "Incoming canddle call"
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        let wasBusy = hasCall || owner?.busy == true || owner?.lobby.waiting == true
        if !wasBusy { uuid = id }
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            completion()
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    if self.uuid == id { self.reset() }
                    return
                }
                guard !wasBusy, self.uuid == id else {
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
                    return
                }
                do {
                    guard type == .voIP, let owner = self.owner else { throw VoiceError.packet }
                    let scope = try RelaySettings(address: owner.address, token: owner.token).url.absoluteString
                    let identity = try LobbyIdentity.load()
                    let ownKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.secret)
                    let ownID = VoiceProtocol.base64(ownKey.publicKey.rawRepresentation)
                    let offer = try IncomingCallPush(payload.dictionaryPayload, scope: scope, recipient: ownID).offer
                    self.seen = self.seen.filter { $0.value > Date().addingTimeInterval(-120) }
                    guard self.seen[offer.id] == nil, self.seen.count < 128 else { throw VoiceError.packet }
                    self.seen[offer.id] = Date()
                    self.offer = offer
                    self.callID = offer.id
                    // Display saved names only after checking the caller's signed offer.
                    update.localizedCallerName = identity.trusted[scope + "|" + offer.identity]
                        ?? "Unverified canddle caller"
                    update.remoteHandle = CXHandle(type: .generic,
                        value: offer.target == nil ? "canddle group call" : "canddle individual call")
                    self.provider.reportCall(with: id, updated: update)
                    self.backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                        Task { @MainActor in self?.end(reason: .failed) }
                    }
                    self.setDeadline(seconds: 30)
                    owner.openLobby(automatic: true)
                } catch { self.end(reason: .failed) }
            }
        }
    }

    private func setDeadline(seconds: UInt64) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                self?.end(reason: .unanswered)
            } catch {}
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard action.callUUID == uuid, let offer, let owner else { action.fail(); return }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            owner.callFailure = "Open canddle and grant microphone access before answering a locked-screen call."
            action.fail()
            end(reason: .failed)
            return
        }
        answer = action
        setDeadline(seconds: 25)
        if owner.lobby.inCall {
            mediaReady()
            return
        }
        joining = Task {
            while !Task.isCancelled, self.uuid == action.callUUID {
                if owner.lobby.online, !owner.lobby.sending,
                   let current = owner.lobby.offers.first(where: { $0.id == offer.id }) {
                    guard current.message == offer.message else { end(reason: .failed); return }
                    guard owner.lobby.trustedName(current.identity) != nil else {
                        owner.callFailure = "Open canddle and verify this caller's security code before joining."
                        end(reason: .failed)
                        return
                    }
                    owner.lobby.request(current)
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
        }
    }

    /// Admission and CallKit audio activation are separate gates.
    func mediaReady() {
        guard let owner, owner.lobby.inCall else { return }
        if let answer {
            do { try configureAudio() }
            catch { end(reason: .failed); return }
            self.answer = nil
            answer.fulfill()
            if audioActive {
                deadline?.cancel()
                owner.startGroupAudio()
            } else {
                setDeadline(seconds: 10)
            }
            return
        }
        if uuid != nil {
            if audioActive {
                owner.startGroupAudio()
            } else if offer != nil, let uuid {
                // Joining via the in-app button must answer the already reported call too.
                controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] error in
                    if error != nil { Task { @MainActor in self?.end(reason: .failed) } }
                }
            }
            return
        }
        let id = UUID()
        uuid = id
        callID = owner.lobby.ownOffer?.id ?? owner.lobby.joining?.offer.id
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic,
            value: owner.lobby.isIndividual ? "canddle individual call" : "canddle group call"))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.end(reason: .failed) }
        }
        setDeadline(seconds: 15)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard uuid == action.callUUID else { action.fail(); return }
        do {
            try configureAudio()
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
            provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
        } catch { action.fail(); end(reason: .failed) }
    }

    private func configureAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]
        )
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioActive = true
        if owner?.lobby.inCall == true {
            deadline?.cancel()
            owner?.startGroupAudio()
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioActive = false
        if hasCall { end(reason: .failed) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == uuid else { action.fulfill(); return }
        let declined = offer
        reset()
        owner?.endSystemCall(declining: declined)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard action.callUUID == uuid, let owner, owner.connected else { action.fail(); return }
        if owner.muted != action.isMuted { owner.mute() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
        end(reason: .failed)
    }

    func providerDidReset(_ provider: CXProvider) {
        reset()
        owner?.endSystemCall()
    }

    func closed(_ call: String) {
        if callID == call { end(reason: .remoteEnded) }
    }

    func disconnected() { if hasCall { end(reason: .remoteEnded) } }

    private func end(reason: CXCallEndedReason) {
        guard let uuid else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        reset()
        owner?.endSystemCall()
    }

    private func reset() {
        uuid = nil
        offer = nil
        callID = nil
        answer?.fail(); answer = nil
        deadline?.cancel(); deadline = nil
        joining?.cancel(); joining = nil
        audioActive = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
