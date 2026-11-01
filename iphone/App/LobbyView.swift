import SwiftUI

struct LobbyView: View {
    @ObservedObject var lobby: GroupStore
    let callBusy: Bool
    let connect: () -> Void
    let startCall: () -> Void

    var body: some View {
        Section {
            Text(lobby.status).font(.callout).accessibilityIdentifier("lobbyStatus")
            if let notification = lobby.notification {
                Label(notification, systemImage: "bell.badge.fill")
                    .foregroundStyle(.blue).accessibilityIdentifier("groupNotification")
                Button("Dismiss notification", action: lobby.dismissNotification)
            }
            if !lobby.active {
                TextField("Device name", text: $lobby.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("lobbyName")
                Button("Go online", action: connect).accessibilityIdentifier("lobbyConnect")
                    .disabled(callBusy)
                Button("Start call", action: startCall).disabled(callBusy)
                Button("Forget verified peers", role: .destructive, action: lobby.forgetPeers)
                    .disabled(callBusy)
            } else {
                Button("Go offline", role: .cancel) { lobby.disconnect() }
                if lobby.online && !lobby.waiting {
                    Button("Start call", action: lobby.announce)
                        .accessibilityIdentifier("lobbyAnnounce").disabled(lobby.sending)
                    ForEach(lobby.offers) { offer in
                        VStack(alignment: .leading, spacing: 8) {
                            peer(offer.identity, name: offer.name)
                            Button("Join call") { lobby.request(offer) }
                                .disabled(lobby.sending)
                        }
                    }
                }
                if !lobby.members.isEmpty {
                    Text("Participants (\(lobby.members.count)/6)").font(.headline)
                    ForEach(lobby.members) { member in
                        VStack(alignment: .leading) {
                            Text(member.id == lobby.ownIdentity ? "\(member.name) (you)" : member.name)
                            Text("Key: \(LobbyProtocol.fingerprint(member.id))")
                                .font(.system(.caption, design: .monospaced))
                            if lobby.isCaller && member.id != lobby.ownIdentity {
                                Button("Remove participant", role: .destructive) { lobby.remove(member) }
                                    .disabled(lobby.sending || lobby.approving != nil)
                            }
                        }
                    }
                }
                if lobby.ownOffer != nil {
                    Text(lobby.visibleCandidates.isEmpty ? "Waiting for join requests" : "Join requests")
                        .font(.headline)
                    ForEach(lobby.visibleCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            peer(candidate.exchange.request.identity, name: candidate.exchange.request.name)
                            verification(candidate.exchange, identity: candidate.exchange.request.identity)
                            Text(candidate.confirmed ? "Peer confirmed. Your approval is still required."
                                 : "Waiting for the peer to verify you and confirm.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(lobby.trustedName(candidate.exchange.request.identity) == nil
                                   ? "Codes match: verify and accept" : "Accept") {
                                lobby.approve(candidate)
                            }.disabled(!candidate.confirmed || lobby.sending || lobby.approving != nil || lobby.members.count >= 6)
                            Button("Reject", role: .destructive) { lobby.reject(candidate) }
                                .disabled(lobby.sending || lobby.approving != nil)
                            Button("Ignore") { lobby.ignore(candidate) }
                        }.padding(.vertical, 8)
                    }
                }
                if let exchange = lobby.joining, !lobby.inCall {
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
                    Button(lobby.inCall ? (lobby.isCaller ? "End call for everyone" : "Leave call") : "Cancel call request",
                           role: .cancel, action: lobby.cancelRequest)
                        .disabled(lobby.sending || lobby.approving != nil)
                }
            }
        } header: {
            Text("Relay Group")
        } footer: {
            Text("Keep both apps open. No locked-screen or background notifications. "
                 + "Announcements are visible to everyone online on this relay. "
                 + "Caller acceptance starts audio. First-time devices compare codes once. "
                 + "The caller controls membership and must stay connected. Up to six participants.")
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
