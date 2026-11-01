import AVFoundation
import Combine
import Foundation
import Security
import UIKit

private struct SavedRelay: Codable {
    let address: String
    let token: String

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "VPComm") + ".relay",
            kSecAttrAccount as String: "saved-relay",
            kSecAttrSynchronizable as String: false
        ]
    }

    static func load() throws -> SavedRelay? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try JSONDecoder().decode(SavedRelay.self, from: data)
    }

    func save() throws {
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(self),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

@MainActor
final class CallStore: ObservableObject {
    let lobby = GroupStore()
    @Published var address = "" { didSet { saveRelay() } }
    @Published var token = "" { didSet { saveRelay() } }
    @Published private(set) var settingsError: String?
    @Published var callFailure: String?
    @Published var invitation = ""
    @Published var importCertificate = false
    @Published var scanningPairing = false
    @Published var pairingTicket: PairingTicket?
    @Published private(set) var pairing = false
    @Published private(set) var status = "Connection details are saved automatically on this iPhone."
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var muted = false
    @Published private(set) var groupAudio = false
    @Published private(set) var verification = ""
    @Published private(set) var rootFingerprint: String?
    private var root: Data?
    private var relay: Relay?
    private var audio: AudioIO?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var clipboardValue: String?
    private var clearingRelay = false
    private var scannedQR: String?

    init() {
        lobby.onAudioReady = { [weak self] in self?.startGroupAudio() }
        lobby.onAudioEnded = { [weak self] message in
            guard let self, self.groupAudio else { return }
            self.task?.cancel()
            self.finish(self.generation, message: message)
        }
        do {
            if let saved = try SavedRelay.load() {
                address = saved.address
                token = saved.token
            }
        } catch {
            settingsError = "Could not read the saved relay. Unlock your iPhone and reopen the app."
        }
    }

    private func saveRelay() {
        guard !clearingRelay else { return }
        if lobby.active { lobby.disconnect("Relay settings changed. Go online again.") }
        do {
            try SavedRelay(address: address, token: token).save()
            settingsError = nil
        } catch {
            settingsError = "Could not save relay details securely. Your edits are only in memory."
        }
    }

    func forgetRelay() {
        guard !busy else { return }
        lobby.disconnect()
        do {
            try SavedRelay.remove()
            clearingRelay = true
            address = ""
            token = ""
            clearingRelay = false
            settingsError = nil
            status = "Saved relay forgotten."
        } catch {
            settingsError = "Could not delete the saved relay. Unlock your iPhone and try again."
        }
    }

    func scannedPairing(_ text: String) {
        guard scanningPairing, !busy else { return }
        scannedQR = text
        scanningPairing = false
    }

    func pairingScannerDismissed() {
        guard let text = scannedQR else { return }
        scannedQR = nil
        guard !busy else { return }
        do {
            pairingTicket = try PairingTicket.parse(text)
        } catch {
            status = "Not a valid VPComm pairing QR. Generate a new code on your server."
        }
    }

    func pairingScanFailed(_ message: String) {
        scannedQR = nil
        scanningPairing = false
        status = message
    }

    func redeemPairing(_ ticket: PairingTicket) {
        guard !busy else { return }
        lobby.disconnect()
        let transport: Relay
        do {
            transport = Relay(try RelaySettings(address: ticket.relay, token: ticket.code, root: root))
        } catch {
            status = "Invalid pairing server."
            return
        }
        pairingTicket = nil
        let id = UUID()
        generation = id
        relay = transport
        busy = true
        pairing = true
        status = "Pairing securely..."
        task = Task {
            do {
                let received = try await transport.redeem(ticket)
                try Task.checkCancellation()
                guard generation == id else { return }
                // Commit both values before changing the UI. A failed write preserves
                // the old saved relay and must not claim successful pairing.
                try SavedRelay(address: ticket.relay, token: received).save()
                clearingRelay = true
                address = ticket.relay
                token = received
                clearingRelay = false
                settingsError = nil
                finish(id, message: "Paired. Relay details saved securely on this iPhone.")
            } catch {
                finish(id, message: "Pairing failed. Check TLS trust and request a fresh QR. "
                       + "Previous saved details were kept.")
            }
        }
    }

    func createInvitation() {
        guard !busy else { return }
        do {
            invitation = try CallInvitation.generate().text
            status = "Invitation ready. Share it privately with your partner."
        } catch { status = "Could not generate a secure invitation." }
    }

    func copyInvitation() {
        guard !busy, !invitation.isEmpty else { return }
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: invitation]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        clipboardValue = invitation
        status = "Copied locally for two minutes. Share only through a trusted channel."
    }

    func loadCertificate(_ url: URL) {
        guard !busy else { return }
        lobby.disconnect()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 32768 else { throw VoiceError.certificate }
            let der = try RelaySettings.certificate(Data(contentsOf: url))
            root = der
            rootFingerprint = RelaySettings.fingerprint(der)
            status = "Private CA loaded. Verify its fingerprint with your administrator."
        } catch { status = "Choose a single PEM or DER public root certificate." }
    }

    func clearCertificate() {
        guard !busy else { return }
        lobby.disconnect()
        root = nil
        rootFingerprint = nil
        status = "Using standard iOS certificate trust."
    }

    func openLobby(startCall: Bool = false) {
        guard !busy else { return }
        do {
            let settings = try RelaySettings(address: address, token: token, root: root)
            lobby.connect(settings, startCall: startCall)
        } catch {
            status = (error as? VoiceError)?.errorDescription ?? "Check relay settings."
            callFailure = status
        }
    }

    private func startGroupAudio() {
        guard !busy else { return }
        let id = UUID()
        generation = id
        groupAudio = true
        busy = true
        callFailure = nil
        status = "Accepted. Checking microphone permission..."
        task = Task {
            do {
                guard await AudioIO.permission() else { throw VoiceError.microphone }
                try Task.checkCancellation()
                guard generation == id, lobby.inCall else { return }
                let audio = AudioIO()
                self.audio = audio
                status = "Starting group microphone and speaker..."
                try audio.start()
                connected = true
                status = "Encrypted group audio. Everyone listed can hear and speak."
                UIApplication.shared.isIdleTimerDisabled = true
                observeAudio(id)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        var lastCapture = ContinuousClock.now
                        while !Task.isCancelled {
                            if let frame = try audio.nextFrame() {
                                lastCapture = .now
                                try await self.lobby.transmit(frame)
                            } else {
                                guard lastCapture.duration(to: .now) < .seconds(5) else {
                                    throw AudioRuntimeError(detail: "No microphone frames arrived for five seconds.")
                                }
                                try await Task.sleep(nanoseconds: 5_000_000)
                            }
                        }
                        throw CancellationError()
                    }
                    group.addTask { @MainActor in
                        let clock = ContinuousClock()
                        var next = clock.now
                        while !Task.isCancelled {
                            try audio.play(self.lobby.mixedFrame())
                            next = max(next.advanced(by: .milliseconds(20)), clock.now)
                            try await clock.sleep(until: next)
                        }
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch {
                guard generation == id else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Group audio failed (error \((error as NSError).code))."
                callFailure = message
                // Disconnect also revokes this participant and closes a caller's group.
                lobby.disconnect(message)
                if generation == id { finish(id, message: message) }
            }
        }
    }

    func start() {
        guard !busy else { return }
        let invitation: CallInvitation
        let relay: Relay
        do {
            invitation = try CallInvitation(self.invitation)
            relay = Relay(try RelaySettings(address: address, token: token, root: root))
        } catch {
            status = (error as? VoiceError)?.errorDescription ?? "Check call details."
            return
        }
        if lobby.active { lobby.disconnect() }
        let id = UUID()
        generation = id
        self.relay = relay
        busy = true
        callFailure = nil
        status = "Checking microphone permission..."
        task = Task {
            var stage = "Microphone permission"
            do {
                guard await AudioIO.permission() else { throw VoiceError.microphone }
                try Task.checkCancellation()
                guard generation == id else { return }
                status = "Connecting securely..."
                stage = "Secure connection"
                let code = try await relay.connect(invitation) {
                    self.status = "Waiting for your partner (up to two minutes)..."
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                let audio = AudioIO()
                self.audio = audio
                stage = "Audio startup"
                status = "Starting microphone and speaker..."
                try audio.start()
                connected = true
                verification = code
                status = "Authenticated call. Compare verification codes independently."
                UIApplication.shared.isIdleTimerDisabled = true
                observeAudio(id)
                stage = "Audio streaming"
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        var lastCapture = ContinuousClock.now
                        while !Task.isCancelled {
                            if let frame = try audio.nextFrame() {
                                lastCapture = .now
                                try await relay.transmit(frame)
                            } else {
                                guard lastCapture.duration(to: .now) < .seconds(5) else {
                                    throw AudioRuntimeError(detail: "No microphone frames arrived for five seconds.")
                                }
                                try await Task.sleep(nanoseconds: 5_000_000)
                            }
                        }
                        throw CancellationError()
                    }
                    group.addTask { @MainActor in
                        while !Task.isCancelled {
                            try audio.play(await relay.listen())
                        }
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
                finish(id, message: "Call ended. Use a new invitation.")
            } catch {
                guard generation == id else { return }
                let detail: String
                if let error = error as? VoiceError {
                    detail = error.errorDescription ?? "Call ended."
                } else if let error = error as? AudioStartupError {
                    detail = error.localizedDescription
                } else if let error = error as? AudioRuntimeError {
                    detail = error.localizedDescription
                } else {
                    let code = (error as NSError).code
                    detail = "Connection ended (error \(code)). Check relay, token, certificate, and network."
                }
                let message = "\(stage): \(detail)"
                callFailure = message
                finish(id, message: message)
            }
        }
    }

    func mute() {
        guard connected else { return }
        muted.toggle()
        audio?.mute(muted)
    }

    func hangUp(_ message: String = "Call ended. Use a new invitation.") {
        guard busy else { return }
        if groupAudio {
            let reason = message == "Call ended. Use a new invitation."
                ? "You left the group call." : message
            lobby.disconnect("\(reason) Go online to receive calls again.")
            return
        }
        task?.cancel()
        finish(generation, message: message)
    }

    func background() {
        lobby.disconnect("Offline because VPComm left the foreground. Go online again to receive calls.")
        hangUp("Call ended because VPComm left the foreground.")
        scannedQR = nil
        scanningPairing = false
        pairingTicket = nil
        // Unused invitations remain in memory so switching apps to share them works.
    }

    private func finish(_ id: UUID, message: String) {
        guard generation == id else { return }
        generation = UUID()
        relay?.stop()
        relay = nil
        audio?.stop()
        audio = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        task = nil
        busy = false
        pairing = false
        connected = false
        groupAudio = false
        muted = false
        verification = ""
        invitation = ""
        status = message
        if let clipboardValue, UIPasteboard.general.string == clipboardValue {
            UIPasteboard.general.items = []
        }
        clipboardValue = nil
    }

    private func observeAudio(_ id: UUID) {
        for event in [AVAudioSession.interruptionNotification,
                      AVAudioSession.routeChangeNotification,
                      AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: event, object: nil, queue: .main
            ) { [weak self] note in
                guard Self.endsCall(note) else { return }
                Task { @MainActor in
                    guard self?.generation == id else { return }
                    self?.hangUp("Audio route changed or was interrupted. Start a new call.")
                }
            })
        }
    }

    /// Configuring and activating the session (category, voice processing) posts
    /// route changes of its own, delivered after observation starts. Only end the
    /// call for real interruptions, lost devices, or a media services reset; other
    /// configuration stops get bounded engine recovery; other breakage is caught
    /// by the capture watchdog. AudioIO separately gates restart on interruption.
    nonisolated private static func endsCall(_ note: Notification) -> Bool {
        let info = note.userInfo ?? [:]
        switch note.name {
        case AVAudioSession.interruptionNotification:
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt
            return raw.flatMap(AVAudioSession.InterruptionType.init) == .began
        case AVAudioSession.routeChangeNotification:
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt
            return raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
        default:
            return true
        }
    }
}
