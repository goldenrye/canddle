import SwiftUI
import UniformTypeIdentifiers
import AudioToolbox

@main
struct CanddleApp: App {
    @UIApplicationDelegateAdaptor(CallAppDelegate.self) private var appDelegate
    @StateObject private var call = CallStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            CallView(call: call, lobby: call.lobby)
                .overlay {
                    if phase != .active {
                        Color(.systemBackground).ignoresSafeArea()
                            .overlay {
                                VStack(spacing: 12) {
                                    Image("BrandLogo").resizable().scaledToFit()
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 22))
                                        .accessibilityHidden(true)
                                    Text("canddle").font(.title)
                                }
                            }
                    }
                }
                .onChange(of: phase) { if $0 == .background { call.background() } }
                .task(id: phase) {
                    guard phase == .active else { return }
                    // Retry only the listening connection, never a call or admission.
                    while !Task.isCancelled {
                        call.connectAutomatically()
                        do {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                        } catch { return }
                    }
                }
        }
    }
}

struct CallView: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore

    private var configured: Bool { !call.address.isEmpty && !call.token.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if call.connected {
                            Image(systemName: "waveform").font(.title2).foregroundStyle(.teal)
                        } else {
                            Image("BrandLogo").resizable().scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(call.connected ? "Encrypted call" : (lobby.online ? "You're online" : "Private group calls"))
                                .font(.headline)
                            Text(call.busy ? call.status : lobby.status)
                                .font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("lobbyStatus")
                        }
                        if (call.busy && !call.connected) || (lobby.active && !lobby.online) {
                            ProgressView().accessibilityLabel("Connecting")
                        }
                    }.padding(.vertical, 6)
                }
                if !configured {
                    Section {
                        Text("Connect to your server once. Your details will be saved securely.")
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            RelaySettingsView(call: call, lobby: lobby)
                        } label: {
                            Label("Set up connection", systemImage: "qrcode.viewfinder")
                        }.accessibilityIdentifier("setupConnection")
                    }
                } else if !call.busy || call.groupAudio {
                    LobbyView(lobby: lobby, callBusy: call.busy,
                              startCall: { call.openLobby(startCall: true) },
                              callMember: { call.openLobby(startCall: true, target: $0) })
                }
            }
            .navigationTitle("Calls")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        RelaySettingsView(call: call, lobby: lobby)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }.accessibilityIdentifier("settings")
                        .disabled(call.busy || lobby.waiting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if call.busy || lobby.waiting {
                    HStack(spacing: 16) {
                        if call.connected {
                            Button(action: call.mute) {
                                Label(call.muted ? "Unmute" : "Mute",
                                      systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
                            }.accessibilityIdentifier("mute")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            if call.busy { call.hangUp() }
                            else { lobby.cancelRequest() }
                        } label: {
                            Label(call.pairing ? "Cancel pairing" :
                                    (lobby.inCall ? (lobby.isIndividual ? "End call" :
                                        (lobby.isCaller ? "End for everyone" : "Leave call")) : "Cancel"),
                                  systemImage: "phone.down.fill")
                        }.accessibilityIdentifier("hangUp")
                            .disabled(!call.busy && (lobby.sending || lobby.approving != nil))
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .padding().background(.regularMaterial)
                }
            }
            .safeAreaInset(edge: .top) {
                if let notification = lobby.notification {
                    HStack {
                        Label(notification, systemImage: "bell.badge.fill").font(.callout)
                        Spacer()
                        Button(action: lobby.dismissNotification) {
                            Image(systemName: "xmark")
                        }.accessibilityLabel("Dismiss notification")
                    }.padding().background(.regularMaterial)
                        .accessibilityIdentifier("incomingCallBanner")
                }
            }
            .onChange(of: lobby.notificationID) { _ in
                AudioServicesPlayAlertSound(SystemSoundID(1007))
                UIAccessibility.post(notification: .announcement, argument: lobby.notification)
            }
            .alert("Call could not continue", isPresented: Binding(
                get: { call.callFailure != nil },
                set: { if !$0 { call.callFailure = nil } }
            )) {
                Button("OK") { call.callFailure = nil }
            } message: {
                Text(call.callFailure ?? "")
            }
        }
    }
}

struct RelaySettingsView: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    @ViewBuilder
    private var microphoneSettings: some View {
        switch call.microphonePermission {
        case .granted:
            Label("Microphone access allowed", systemImage: "checkmark.circle")
                .accessibilityIdentifier("microphoneAllowed")
        case .denied:
            Text("Microphone access denied. Enable Microphone in iPhone Settings to speak on calls.")
                .accessibilityIdentifier("microphoneDenied")
            Button("Open iPhone Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("microphoneSettings")
            .disabled(call.busy)
        case .undetermined:
            Text("Microphone access not requested")
                .accessibilityIdentifier("microphoneNotRequested")
            Button("Allow microphone access") {
                Task { await call.requestMicrophonePermission() }
            }
            .accessibilityIdentifier("requestMicrophone")
            .disabled(call.busy || call.requestingMicrophonePermission)
        @unknown default:
            Text("Microphone permission is unavailable. Check iPhone Settings.")
        }
        if call.requestingMicrophonePermission {
            ProgressView("Waiting for microphone permission")
        }
        Text("This grants access only; it does not start recording. Background ringing requires Apple push setup separately.")
            .font(.caption).foregroundStyle(.secondary)
    }

    var body: some View {
        Group {
            Form {
                Section("Your device") {
                    Text(lobby.pushStatus).font(.caption).foregroundStyle(.secondary)
                    microphoneSettings
                    HStack {
                        TextField("Device name", text: $call.deviceNameDraft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("lobbyName").focused($editing)
                            .disabled(call.busy || lobby.waiting)
                        Button {
                            if call.saveDeviceName(call.deviceNameDraft) {
                                call.deviceNameDraft = lobby.name
                                editing = false
                            }
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.body)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Save name")
                        .accessibilityIdentifier("saveDeviceName")
                        .help("Save name")
                        .disabled(call.busy || lobby.waiting || call.deviceNameDraft == lobby.name)
                    }
                    if let error = call.nameError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("Saved on this iPhone. Used for future calls; verified peers may still see the name they saved.")
                        .font(.caption).foregroundStyle(.secondary)
                    if lobby.active {
                        Text("Go offline before editing connection settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Go offline") { lobby.disconnect() }
                            .disabled(call.busy || lobby.waiting)
                    }
                }
                Section {
                    Button {
                        editing = false
                        call.scanningPairing = true
                    } label: {
                        Label("Pair with QR", systemImage: "qrcode.viewfinder")
                    }.accessibilityIdentifier("pairQR")
                    DisclosureGroup("Enter connection manually") {
                        TextField("wss://voice.example.com/relay", text: $call.address)
                            .keyboardType(.URL).focused($editing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("address")
                        SecureField("Relay access token", text: $call.token)
                            .focused($editing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("token")
                    }
                    if let error = call.settingsError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Address and token are saved automatically in this iPhone's Keychain. "
                         + "They are not synced through iCloud.")
                }.disabled(call.busy || lobby.active)
                Section {
                    Toggle("Auto-accept verified family devices", isOn: $call.autoAcceptVerifiedDevices)
                        .accessibilityIdentifier("autoAcceptVerifiedDevices")
                        .disabled(call.busy || lobby.waiting)
                } header: {
                    Text("Call admission")
                } footer: {
                    Text("Off by default. When you start a call, any device previously verified on this relay "
                         + "can join without another Accept tap after it requests to join and confirms your identity. "
                         + "Enable only if all your verified devices belong to people you want to admit automatically. "
                         + "New devices still require manual verification. This does not automatically answer incoming calls.")
                }
                Section("Advanced") {
                    DisclosureGroup("Certificate trust") {
                        if let fingerprint = call.rootFingerprint {
                            Label("Private CA loaded", systemImage: "checkmark.shield")
                            Text("SHA-256: \(fingerprint)")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Use standard iOS trust", action: call.clearCertificate)
                        } else {
                            Text("Standard iOS certificate trust").foregroundStyle(.secondary)
                        }
                        Button("Choose private CA certificate") { call.importCertificate = true }
                            .accessibilityIdentifier("importCA")
                        Text("Only for privately issued certificates. Verify the public root's fingerprint independently.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Reset saved settings") {
                        Button("Forget saved relay", role: .destructive, action: call.forgetRelay)
                            .accessibilityIdentifier("forgetRelay")
                        Button("Forget verified peers", role: .destructive, action: lobby.forgetPeers)
                    }
                }.disabled(call.busy || lobby.active)
                Section {
                    DisclosureGroup("Privacy & limits") {
                        Text("Accepted calls continue while locked. Background ringing requires "
                             + "Apple push setup on this app and relay. Audio interruptions end calls.")
                        Text("Group microphones start after verified caller acceptance. The caller controls "
                             + "who joins; check the participant list. Verify new device codes through "
                             + "a trusted channel. Headphones are recommended.")
                        Text("Experimental protocol, not independently audited. The relay sees IP "
                             + "addresses and timing. Your partner can record the conversation.")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                Section("Setup status") {
                    Text(call.status).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                    if call.pairing {
                        ProgressView("Pairing securely")
                        Button("Cancel pairing", role: .cancel) { call.hangUp() }
                    }
                }
                Section("About") {
                    LabeledContent("App", value: "Canddle")
                    LabeledContent("Version", value: appVersion)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Version")
                        .accessibilityValue(appVersion)
                        .accessibilityIdentifier("appVersion")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
            .fileImporter(isPresented: $call.importCertificate, allowedContentTypes: [.data]) {
                if case .success(let url) = $0 { call.loadCertificate(url) }
            }
            .sheet(isPresented: $call.scanningPairing, onDismiss: call.pairingScannerDismissed) {
                NavigationStack {
                    PairingScanner(scanned: call.scannedPairing, failed: call.pairingScanFailed)
                        .navigationTitle("Scan server QR")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { call.scanningPairing = false }
                            }
                        }
                }
            }
            .alert("Pair with this server?", isPresented: Binding(
                get: { call.pairingTicket != nil },
                set: { if !$0 { call.pairingTicket = nil } }
            ), presenting: call.pairingTicket) { ticket in
                Button("Pair and save") { call.redeemPairing(ticket) }
                Button("Cancel", role: .cancel) { call.pairingTicket = nil }
            } message: { ticket in
                Text("\(ticket.relay)\n\nOnly continue for a QR from your trusted server administrator. "
                     + "This replaces your saved relay. "
                     + (call.rootFingerprint == nil ? "Using standard iOS TLS trust."
                        : "Using your imported private CA. Verify its fingerprint first."))
            }
        }
        .onAppear {
            call.settingsVisible = true
            call.deviceNameDraft = lobby.name
            call.refreshMicrophonePermission()
        }
        .onChange(of: phase) { phase in
            if phase == .active { call.refreshMicrophonePermission() }
        }
        .onDisappear {
            call.settingsVisible = false
            call.connectAutomatically()
        }
    }

}
