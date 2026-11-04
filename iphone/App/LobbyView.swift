import SwiftUI

struct LobbyView: View {
    @ObservedObject var lobby: GroupStore
    let callBusy: Bool
    let startCall: () -> Void
    let callMember: (String) -> Void

    var body: some View {
        if !lobby.waiting && !callBusy {
            Section {
                Button(action: startCall) {
                    Label("Start group call", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("lobbyAnnounce")
                .disabled(lobby.sending || (lobby.active && !lobby.online))
            } footer: {
                Text("Invite the group, or use a member's phone icon for an individual call.")
            }
            if lobby.online {
                Section("Available calls") {
                    if lobby.offers.isEmpty {
                        Label("No calls right now", systemImage: "phone.badge.waveform")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lobby.offers) { offer in
                        VStack(alignment: .leading, spacing: 8) {
                            peer(offer.identity, name: offer.name)
                            Text(offer.target == nil ? "Group call" : "Individual call")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(offer.target == nil ? "Join group call" : "Answer") { lobby.request(offer) }
                                    .buttonStyle(.borderedProminent)
                                if offer.target != nil {
                                    Button("Decline", role: .destructive) { lobby.decline(offer) }
                                        .buttonStyle(.bordered)
                                }
                            }.disabled(lobby.sending)
                        }
                    }
                }
            }
        }
        if lobby.ownOffer != nil {
            if !lobby.visibleCandidates.isEmpty {
                Section("Join requests (\(lobby.visibleCandidates.count))") {
                    ForEach(lobby.visibleCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            peer(candidate.exchange.request.identity, name: candidate.exchange.request.name)
                            verification(candidate.exchange, identity: candidate.exchange.request.identity)
                            Text(candidate.confirmed ? "Ready for your approval"
                                 : "Waiting for this person to confirm your identity")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(lobby.trustedName(candidate.exchange.request.identity) == nil
                                   ? "Codes match: verify and accept" : "Accept") {
                                lobby.approve(candidate)
                            }.disabled(!candidate.confirmed || lobby.sending || lobby.approving != nil || lobby.members.count >= lobby.memberLimit)
                                .buttonStyle(.borderedProminent)
                            HStack {
                                Button("Reject", role: .destructive) { lobby.reject(candidate) }
                                Spacer()
                                Button("Ignore") { lobby.ignore(candidate) }
                            }.buttonStyle(.borderless)
                                .disabled(lobby.sending || lobby.approving != nil)
                        }.padding(.vertical, 8)
                    }
                }
            } else if !lobby.inCall {
                Section {
                    if let target = lobby.ownOffer?.target {
                        peer(target, name: lobby.groupDirectory.first { $0.id == target }?.name ?? "Selected device")
                    }
                    Label(lobby.isIndividual ? "Waiting for an answer" : "Waiting for join requests",
                          systemImage: "person.badge.clock")
                    Text(lobby.isIndividual
                         ? "Only the selected device is invited. Both devices need an updated app."
                         : "Your group call is visible to everyone online on this relay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if let exchange = lobby.joining, !lobby.inCall {
            Section(lobby.confirmed ? "Waiting for acceptance" : "Verify this device") {
                VStack(alignment: .leading, spacing: 10) {
                    peer(exchange.offer.identity, name: exchange.offer.name)
                    verification(exchange, identity: exchange.offer.identity)
                    if !lobby.confirmed {
                        Button("Codes match: request approval") {
                            lobby.confirmCaller()
                        }.buttonStyle(.borderedProminent).disabled(lobby.sending)
                    }
                }
            }
        }
        if !lobby.members.isEmpty {
            Section("Participants (\(lobby.members.count)/\(lobby.memberLimit))") {
                ForEach(lobby.members) { member in
                    DisclosureGroup {
                        Text("Device key: \(LobbyProtocol.fingerprint(member.id))")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if lobby.isCaller && member.id != lobby.ownIdentity {
                            Button(lobby.isIndividual ? "End call" : "Remove participant", role: .destructive) { lobby.remove(member) }
                                .disabled(lobby.sending || lobby.approving != nil)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(member.id == lobby.ownIdentity ? "\(member.name) (you)" : member.name,
                                  systemImage: member.id == lobby.ownIdentity ? "person.fill" : "person")
                            Text(lobby.inCall ? "In call" : "Waiting for participants")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section {
            if lobby.groupDirectory.isEmpty {
                Text("Members appear when devices connect to this relay.")
                    .foregroundStyle(.secondary)
            }
            ForEach(lobby.groupDirectory) { member in
                HStack {
                    DisclosureGroup {
                        Text("Device key: \(LobbyProtocol.fingerprint(member.id))")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(member.id == lobby.localIdentity ? "This device"
                             : (lobby.trustedName(member.id) != nil ? "Previously verified device key"
                                : "Unverified device. Verify its security code before joining a call."))
                            .font(.caption).foregroundStyle(.secondary)
                    } label: {
                        HStack {
                            Text(member.id == lobby.localIdentity ? "\(member.name) (you)" : member.name)
                            Spacer()
                            Label(member.state.label, systemImage: presenceIcon(member.state))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("groupMember-\(member.id)")
                    if member.id != lobby.localIdentity {
                        Button { callMember(member.id) } label: {
                            Image(systemName: "phone.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Call \(member.name)")
                        .accessibilityIdentifier("callMember-\(member.id)")
                        .disabled(callBusy || lobby.waiting || lobby.sending || !lobby.online
                                  || !lobby.directCallsSupported
                                  || [.calling, .joining, .inCall].contains(member.state))
                    }
                }
            }
        } header: {
            Text("Group members (\(lobby.groupDirectory.count))")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !lobby.online {
                    Text("Connect to refresh member statuses.")
                } else if !lobby.directCallsSupported {
                    Text("Upgrade the relay to enable individual call icons.")
                } else if !lobby.presenceSupported {
                    Text("Upgrade the relay to see live member statuses.")
                } else if !lobby.presenceReady {
                    Text("Loading member statuses...")
                } else if lobby.presenceTruncated {
                    Text("Only the first 32 connected devices are shown. Other statuses are unknown.")
                }
                Text("Relay-reported connection status, not microphone or delivery status. "
                     + "A device marked Not connected may still receive calls through Apple push. "
                     + "Includes devices seen this session and saved verified peers.")
            }
        }
    }

    private func presenceIcon(_ state: GroupPresenceState) -> String {
        switch state {
        case .online: return "circle.fill"
        case .calling: return "phone.arrow.up.right"
        case .joining: return "person.badge.clock"
        case .inCall: return "phone.fill"
        case .disconnected: return "circle"
        case .unknown: return "questionmark.circle"
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
            DisclosureGroup("Device identity") {
                Text("Key: \(LobbyProtocol.fingerprint(identity))")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.font(.caption)
        }
    }

    private func verification(_ exchange: LobbyExchange, identity: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if lobby.trustedName(identity) == nil {
                Text(exchange.code).font(.system(.callout, design: .monospaced))
                    .accessibilityIdentifier("lobbyVerification")
                Text("Compare this entire code with the intended person in person or through "
                     + "an independent trusted channel. A name is not proof of identity. "
                     + "Only confirm if the codes match; this remembers their device key.")
                    .font(.caption)
            } else {
                Text("This device key matches your saved verification.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Compare security code") {
                    Text(exchange.code).font(.system(.callout, design: .monospaced))
                        .accessibilityIdentifier("lobbyVerification")
                }.font(.caption)
            }
        }
    }
}
