import SwiftUI
import UniformTypeIdentifiers

@main
struct VPCommApp: App {
    @StateObject private var call = CallStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            CallView(call: call)
                .overlay {
                    if phase != .active {
                        Color(.systemBackground).ignoresSafeArea()
                            .overlay(Label("VPComm", systemImage: "lock.shield").font(.title))
                    }
                }
                .onChange(of: phase) { if $0 == .background { call.background() } }
        }
    }
}

struct CallView: View {
    @ObservedObject var call: CallStore
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A private line for two", systemImage: "lock.shield.fill").font(.headline)
                    Text("Your relay. End-to-end encrypted audio.").foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        editing = false
                        call.scanningPairing = true
                    } label: {
                        Label("Pair with QR", systemImage: "qrcode.viewfinder")
                    }.accessibilityIdentifier("pairQR")
                    TextField("wss://voice.example.com/relay", text: $call.address)
                        .keyboardType(.URL).focused($editing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("address")
                    SecureField("Relay access token", text: $call.token)
                        .focused($editing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("token")
                    if let error = call.settingsError {
                        Text(error).foregroundStyle(.red)
                    }
                    Button("Forget saved relay", role: .destructive, action: call.forgetRelay)
                        .accessibilityIdentifier("forgetRelay")
                } header: {
                    Text("Relay")
                } footer: {
                    Text("Address and token are saved automatically in this iPhone's Keychain. "
                         + "They are not synced through iCloud.")
                }.disabled(call.busy)
                Section {
                    SecureField("Paste vp1 invitation", text: $call.invitation)
                        .focused($editing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("invitation")
                    HStack {
                        Button("New invitation", action: call.createInvitation)
                            .accessibilityIdentifier("newInvitation")
                        Spacer()
                        Button("Copy", action: call.copyInvitation).disabled(call.invitation.isEmpty)
                    }.buttonStyle(.borderless)
                } header: {
                    Text("Invitation")
                } footer: {
                    Text("Share privately. Anyone holding the "
                         + "invitation can join as your partner. Use a new one for every call.")
                }.disabled(call.busy)
                Section("Call") {
                    Text(call.status).accessibilityIdentifier("status")
                    if call.connected {
                        Text(call.verification).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(action: call.mute) {
                            Label(call.muted ? "Unmute" : "Mute",
                                  systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
                        }.accessibilityIdentifier("mute")
                    }
                    if call.busy {
                        Button(role: .destructive) { call.hangUp() } label: {
                            Label(call.pairing ? "Cancel pairing" : "Hang up",
                                  systemImage: "phone.down.fill")
                        }.accessibilityIdentifier("hangUp")
                    } else {
                        Button {
                            editing = false
                            call.start()
                        } label: {
                            Label("Start / Join", systemImage: "phone.fill")
                        }.accessibilityIdentifier("start")
                            .disabled(call.address.isEmpty || call.token.isEmpty || call.invitation.isEmpty)
                    }
                }
                Section {
                    if let fingerprint = call.rootFingerprint {
                        Label("Private CA loaded", systemImage: "checkmark.shield")
                        Text("SHA-256: \(fingerprint)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Use standard iOS trust", action: call.clearCertificate)
                    } else {
                        Text("Standard iOS certificate trust").foregroundStyle(.secondary)
                    }
                    Button("Import private CA from Files") { call.importCertificate = true }
                } header: {
                    Text("TLS certificate")
                } footer: {
                    Text("Only needed for a privately issued server certificate. "
                         + "Import its public root CA and verify the fingerprint independently.")
                }.disabled(call.busy)
                Section("Privacy & Limits") {
                    Text("Keep this app open. Backgrounding, locking, or changing the audio route "
                         + "ends the call. Saved relay details are kept for your next call.")
                    Text("Microphone capture starts after peer key confirmation. Compare the "
                         + "verification codes through a trusted channel. Headphones are recommended.")
                    Text("Experimental protocol, not independently audited. The relay sees IP "
                         + "addresses and timing. Your partner can record the conversation.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("VPComm")
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
    }
}
