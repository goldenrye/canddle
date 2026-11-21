import AVFoundation
import CallKit
import CryptoKit
import PushKit
import UIKit
import UserNotifications

/// Created at process launch, including launches caused by a VoIP push.
@MainActor
final class CallAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CallStore.shared.systemCalls.register()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let messages = CallStore.shared.messages
        messages.notificationError = nil
        messages.notificationToken = token.map { String(format: "%02x", $0) }.joined()
        messages.environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "development"
        Task { await messages.flush() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CallStore.shared.messages.notificationError =
            "Apple message alerts could not register. Check network access and app push provisioning, then enable notifications again."
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        if response.notification.request.content.userInfo["canddle_message"] as? Bool == true {
            CallStore.shared.messages.showInbox = true
        }
        completion()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let call = CallStore.shared
        let message = notification.request.content.userInfo["canddle_message"] as? Bool == true
        completion(message && !call.busy && !call.messages.showInbox ? [.banner] : [])
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
    private var incomingScope: String?
    private var answer: CXAnswerCallAction?
    private var deadline: Task<Void, Never>?
    private var joining: Task<Void, Never>?
    private var audioActive = false
    private var outgoingAudio = OutgoingCallAudio()
    private var ringback: AVAudioPlayer?
    private static let ringbackData = RingbackTone.wave()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var seen: [String: Date] = [:]
    var hasCall: Bool { uuid != nil }

    init(owner: CallStore) {
        self.owner = owner
        let config = CXProviderConfiguration()
        config.iconTemplateImageData = CallBranding.iconTemplate()
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
        // Authenticate and persist before handing completion back to PushKit. CallKit actions
        // can arrive before its report callback, and iOS may suspend us after completion.
        let id = UUID()
        seen = seen.filter { $0.value > Date().addingTimeInterval(-120) }
        let incoming = type == .voIP ? authenticatedIncoming(payload.dictionaryPayload) : nil
        let duplicate = incoming.map { seen[$0.offer.id] != nil } ?? false
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Canddle")
        update.localizedCallerName = incoming?.name ?? "Incoming Canddle call"
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        let wasBusy = hasCall || owner?.busy == true || owner?.lobby.waiting == true
        if let incoming, !duplicate {
            seen[incoming.offer.id] = Date()
            owner?.missedCalls.receive(incoming.offer, scope: incoming.scope, name: incoming.name, timeout: 30)
            if !wasBusy {
                uuid = id
                offer = incoming.offer
                callID = incoming.offer.id
                incomingScope = incoming.scope
                backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                    Task { @MainActor in self?.end(reason: .unanswered) }
                }
                setDeadline(seconds: 30)
            }
            update.remoteHandle = CXHandle(type: .generic,
                value: incoming.offer.target == nil ? "Canddle group call" : "Canddle individual call")
        }
        // Report every VoIP push, including invalid ones, without waiting for network work.
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                defer { completion() }
                guard let self else { return }
                if let error = error as NSError? {
                    if let incoming, !duplicate {
                        if error.domain == CXErrorDomainIncomingCall,
                           error.code == CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue {
                            self.owner?.missedCalls.closed(incoming.offer.id, scope: incoming.scope)
                        } else {
                            self.owner?.missedCalls.handled(incoming.offer.id, scope: incoming.scope)
                        }
                    }
                    if self.uuid == id { self.reset() }
                    return
                }
                guard let incoming else {
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .failed)
                    return
                }
                guard !duplicate, !wasBusy, self.uuid == id else {
                    if !duplicate, self.callID != incoming.offer.id {
                        self.owner?.missedCalls.closed(incoming.offer.id, scope: incoming.scope)
                    }
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
                    return
                }
                self.owner?.openLobby(automatic: true)
            }
        }
    }

    private func authenticatedIncoming(_ payload: [AnyHashable: Any])
        -> (offer: LobbyOffer, scope: String, name: String)? {
        do {
            guard let owner, seen.count < 128 else { return nil }
            let scope = try RelaySettings(address: owner.address, token: owner.token).url.absoluteString
            let identity = try LobbyIdentity.load()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.secret)
            let recipient = VoiceProtocol.base64(key.publicKey.rawRepresentation)
            let offer = try IncomingCallPush(payload, scope: scope, recipient: recipient).offer
            let verified = identity.trusted[scope + "|" + offer.identity] != nil
            return (offer, scope, offer.callerDisplayName(verified: verified))
        } catch { return nil }
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
        if let incomingScope { owner.missedCalls.handled(offer.id, scope: incomingScope) }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            owner.callFailure = "Open Canddle and grant microphone access before answering a locked-screen call."
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
                        owner.callFailure = "Open Canddle and verify this caller's security code before joining."
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
        outgoingAudio.admit()
        stopRingback()
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
                deadline?.cancel(); deadline = nil
                owner.startGroupAudio()
            } else if offer != nil, let uuid {
                // Joining via the in-app button must answer the already reported call too.
                controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] error in
                    if error != nil { Task { @MainActor in self?.end(reason: .failed) } }
                }
            }
            return
        }
        startCall(call: owner.lobby.ownOffer?.id ?? owner.lobby.joining?.offer.id,
                  individual: owner.lobby.isIndividual, admitted: true)
    }

    func outgoing(_ offer: LobbyOffer) {
        guard uuid == nil, owner?.lobby.ownOffer?.id == offer.id else { return }
        startCall(call: offer.id, individual: offer.target != nil, admitted: false)
    }

    private func startCall(call: String?, individual: Bool, admitted: Bool) {
        let id = UUID()
        uuid = id
        callID = call
        outgoingAudio.start(admitted: admitted)
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic,
            value: individual ? "Canddle individual call" : "Canddle group call"))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard self?.uuid == id else { return }
                self?.end(reason: .failed)
            }
        }
        setDeadline(seconds: 15)
    }

    func mediaConnected() {
        guard let uuid, outgoingAudio.connect() else { return }
        stopRingback()
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard uuid == action.callUUID else { action.fail(); return }
        do {
            try configureAudio()
            action.fulfill()
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        } catch { action.fail(); end(reason: .failed) }
    }

    private func configureAudio() throws {
        if owner?.lobby.usesWebRTC == true {
            try WebRTCAudio.configureAudio()
            return
        }
        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .voiceChat, options: [.allowBluetooth]
        )
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard hasCall else { return }
        audioActive = true
        outgoingAudio.activate()
        WebRTCAudio.activate(audioSession)
        if owner?.lobby.inCall == true {
            outgoingAudio.admit()
            stopRingback()
            deadline?.cancel()
            owner?.startGroupAudio()
        } else if outgoingAudio.shouldPlayRingback {
            setDeadline(seconds: 120)
            stopRingback()
            do {
                let player = try AVAudioPlayer(data: Self.ringbackData)
                player.numberOfLoops = -1
                player.volume = 0.5
                guard player.play() else { throw VoiceError.audio }
                ringback = player
            } catch {
                // Ringback failure must not prevent the peer answering.
                owner?.callFailure = "Could not play the dialing tone. The call request is still active."
            }
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        stopRingback()
        outgoingAudio.deactivate()
        audioActive = false
        WebRTCAudio.deactivate(audioSession)
        if hasCall { end(reason: .failed) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard action.callUUID == uuid else { action.fulfill(); return }
        let declined = offer
        if let offer, let incomingScope {
            owner?.missedCalls.declined(offer.id, scope: incomingScope)
        }
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
        recordUnansweredEnd()
        reset()
        owner?.endSystemCall()
    }

    func closed(_ call: String) {
        if callID == call { end(reason: .remoteEnded) }
    }

    func disconnected() {
        // An unavailable relay must not erase an unanswered push. Its ringing deadline still applies.
        if let offer, let incomingScope,
           owner?.missedCalls.isRinging(offer.id, scope: incomingScope) == true { return }
        if hasCall { end(reason: .failed) }
    }

    private func end(reason: CXCallEndedReason) {
        guard let uuid else { return }
        recordUnansweredEnd()
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        reset()
        owner?.endSystemCall()
    }

    private func recordUnansweredEnd() {
        if let offer, let incomingScope {
            owner?.missedCalls.closed(offer.id, scope: incomingScope)
        }
    }

    private func reset() {
        stopRingback()
        outgoingAudio.reset()
        uuid = nil
        offer = nil
        callID = nil
        incomingScope = nil
        answer?.fail(); answer = nil
        deadline?.cancel(); deadline = nil
        joining?.cancel(); joining = nil
        audioActive = false
        owner?.resetSpeaker()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func stopRingback() {
        ringback?.stop()
        ringback = nil
    }
}
