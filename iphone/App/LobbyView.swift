import SwiftUI

struct LobbyView: View {
    @ObservedObject var lobby: LobbyStore
    let callBusy: Bool
    let connect: () -> Void

    var body: some View {
        Section {
            Text(lobby.status).font(.callout).accessibilityIdentifier("lobbyStatus")
            if !lobby.active {
                TextField("Device name", text: $lobby.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("lobbyName")
                Button("Go online", action: connect).accessibilityIdentifier("lobbyConnect")
                    .disabled(callBusy)
                Button("Forget verified peers", role: .destructive, action: lobby.forgetPeers)
                    .disabled(callBusy)
            } else {
                Button("Go offline", role: .cancel) { lobby.disconnect() }
                if lobby.online && !lobby.waiting {
                    Button("New call", action: lobby.announce)
                        .accessibilityIdentifier("lobbyAnnounce").disabled(lobby.sending)
                    ForEach(lobby.offers) { offer in
                        VStack(alignment: .leading, spacing: 8) {
                            peer(offer.identity, name: offer.name)
                            Button("Request to join") { lobby.request(offer) }
                                .disabled(lobby.sending)
                        }
                    }
                }
                if lobby.ownOffer != nil {
                    Text(lobby.candidates.isEmpty ? "Waiting for join requests" : "Join requests")
                        .font(.headline)
                    ForEach(lobby.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            peer(candidate.exchange.request.identity, name: candidate.exchange.request.name)
                            verification(candidate.exchange, identity: candidate.exchange.request.identity)
                            Text(candidate.confirmed ? "Peer confirmed. Your approval is still required."
                                 : "Waiting for the peer to verify you and confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(lobby.trustedName(candidate.exchange.request.identity) == nil
                                   ? "Codes match: verify and approve" : "Approve and start call") {
                                lobby.approve(candidate)
                            }.disabled(!candidate.confirmed || lobby.sending || lobby.approving != nil)
                            Button("Reject", role: .destructive) { lobby.reject(candidate) }
                                .disabled(lobby.sending || lobby.approving != nil)
                        }.padding(.vertical, 8)
                    }
                }
                if let exchange = lobby.joining {
                    VStack(alignment: .leading, spacing: 10) {
                        peer(exchange.offer.identity, name: exchange.offer.name)
                        verification(exchange, identity: exchange.offer.identity)
                        if !lobby.confirmed {
                            Button(lobby.trustedName(exchange.offer.identity) == nil
                                   ? "Codes match: verify and request approval" : "Confirm and request approval") {
                                lobby.confirmCaller()
                            }.disabled(lobby.sending)
                        }
                    }
                }
                if lobby.waiting {
                    Button("Cancel call request", role: .cancel, action: lobby.cancelRequest)
                        .disabled(lobby.sending || lobby.approving != nil)
                }
            }
        } header: {
            Text("Call Lobby")
        } footer: {
            Text("Keep both apps open. No locked-screen or background notifications. "
                 + "Announcements are visible to everyone online on this relay. "
                 + "After both sides confirm, caller approval starts the microphone and call.")
        }
    }

    private func peer(_ identity: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let saved = lobby.trustedName(identity) {
                Label("Verified device: \(saved)", systemImage: "checkmark.shield.fill")
                if name != saved { Text("Current name: \(name)").font(.caption) }
            } else {
                Label("Unverified: \(name)", systemImage: "person.crop.circle.badge.questionmark")
            }
            Text("Key: \(LobbyProtocol.fingerprint(identity))")
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func verification(_ exchange: LobbyExchange, identity: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.code).font(.system(.callout, design: .monospaced))
                .accessibilityIdentifier("lobbyVerification")
            if lobby.trustedName(identity) == nil {
                Text("Compare this entire code with the intended person in person or through "
                     + "an independent trusted channel. A name is not proof of identity. "
                     + "Only confirm if the codes match; this remembers their device key.")
                    .font(.caption)
            } else {
                Text("This device key matches your saved verification.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
