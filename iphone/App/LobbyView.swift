import SwiftUI

struct LobbyView: View {
    @ObservedObject var lobby: GroupStore
    @ObservedObject var call: CallStore
    let callBusy: Bool
    let startCall: () -> Void
    let callMember: (String) -> Void

    var body: some View {
        if !lobby.waiting && !callBusy {
            incomingCalls
            memberDirectory
            Section {
                Button(action: startCall) {
                    Label("Start group call", systemImage: "person.2.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("lobbyAnnounce")
                .disabled(lobby.sending || (lobby.active && !lobby.online))
            } footer: {
                Text("Call the group together, or use a member's phone button for a private call.")
            }
            .confirmationDialog("WebRTC is unavailable on this relay", isPresented: Binding(
                get: { lobby.pendingLegacyCall != nil },
                set: { if !$0 { lobby.dismissLegacyCallRequest() } }
            ), titleVisibility: .visible, presenting: lobby.pendingLegacyCall) { request in
                Button(request.target == nil ? "Start legacy group call" : "Start legacy individual call") {
                    lobby.confirmLegacyCall(request)
                }.accessibilityIdentifier("confirmLegacyCall")
                Button("Cancel", role: .cancel) { lobby.dismissLegacyCallRequest() }
            } message: { _ in
                Text("Use the existing encrypted TCP audio for this call? Verification and admission stay "
                     + "the same, but audio may still be choppy. Your WebRTC setting will stay on. "
                     + "To use WebRTC, configure TURN on the relay.")
            }
        }
        if lobby.ownOffer != nil {
            if !lobby.visibleCandidates.isEmpty {
                Section("Needs your attention (\(lobby.visibleCandidates.count))") {
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
        if lobby.inCall && !lobby.members.isEmpty {
            Section("Participants (\(lobby.members.count)/\(lobby.memberLimit))") {
                ForEach(lobby.members) { member in
                    DisclosureGroup {
                        if callBusy && member.id != lobby.ownIdentity {
                            CallMediaIndicator(quality: call.mediaQuality, connected: call.connected,
                                               peer: member.id, details: true)
                        }
                        Text("Device key: \(LobbyProtocol.fingerprint(member.id))")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if lobby.isCaller && member.id != lobby.ownIdentity {
                            Button(lobby.isIndividual ? "End call" : "Remove participant", role: .destructive) { lobby.remove(member) }
                                .disabled(lobby.sending || lobby.approving != nil)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            MemberAvatar(identity: member.id, isYou: member.id == lobby.ownIdentity,
                                         photos: call.profilePhoto, remote: lobby.profiles[member.id]?.photo)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(member.id == lobby.ownIdentity ? "\(member.name) (you)" : member.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if callBusy && member.id != lobby.ownIdentity {
                                    CallMediaIndicator(quality: call.mediaQuality, connected: call.connected,
                                                       peer: member.id)
                                } else {
                                    Text(lobby.recoveringMedia ? "Reconnecting audio"
                                         : (!call.connected ? "Connecting audio"
                                            : (call.muted ? "Microphone muted" : "Microphone on")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        if (lobby.waiting || callBusy) && !directoryMembers.isEmpty {
            memberDirectory
        }
    }

    @ViewBuilder
    private var incomingCalls: some View {
        if lobby.online && !lobby.offers.isEmpty {
            Section("Incoming calls") {
                // Targeted invitations take precedence over open group calls.
                ForEach(lobby.offers.filter { $0.target != nil } + lobby.offers.filter { $0.target == nil }) { offer in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(offer.target == nil ? "Group call invitation" : "Calling you",
                              systemImage: offer.target == nil ? "person.2.fill" : "phone.arrow.down.left")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                        HStack(alignment: .top, spacing: 12) {
                            MemberAvatar(identity: offer.identity, isYou: false, photos: call.profilePhoto,
                                         remote: lobby.profiles[offer.identity]?.photo)
                            peer(offer.identity, name: offer.name)
                        }
                        HStack {
                            Button(offer.target == nil ? "Join group call" : "Answer") { lobby.request(offer) }
                                .buttonStyle(.borderedProminent)
                            if offer.target != nil {
                                Button("Decline", role: .destructive) { lobby.decline(offer) }
                                    .buttonStyle(.bordered)
                            }
                        }.disabled(lobby.sending)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("incomingOffer-\(offer.id)")
                }
            }
        }
    }

    private var directoryMembers: [GroupPresence] {
        let occupied = Set(lobby.members.map(\.id))
        return lobby.groupDirectory.filter {
            !(lobby.waiting || callBusy)
                || ($0.id != lobby.localIdentity && !occupied.contains($0.id)
                    && $0.id != lobby.ownOffer?.target && $0.id != lobby.joining?.offer.identity)
        }
    }

    private var memberDirectory: some View {
        Section {
            if lobby.waiting || callBusy {
                DisclosureGroup("Other group members (\(directoryMembers.count))") { directoryRows }
                    .accessibilityIdentifier("otherGroupMembers")
            } else {
                directoryRows
            }
        } header: {
            if !lobby.waiting && !callBusy {
                Text("Group members (\(directoryMembers.count))")
                    .accessibilityIdentifier("groupMembersHeader")
            }
        } footer: {
            if !lobby.waiting && !callBusy {
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
                    Text("Status is relay-reported; offline members may still receive calls through Apple push.")
                }
            }
        }
    }

    private var directoryRows: some View {
        Group {
            if directoryMembers.isEmpty {
                Text("No other members yet. Connect another device to the same relay to see it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(directoryMembers) { member in
                HStack(alignment: .top, spacing: 12) {
                    MemberAvatar(identity: member.id, isYou: member.id == lobby.localIdentity,
                                 photos: call.profilePhoto, remote: lobby.profiles[member.id]?.photo)
                    DisclosureGroup {
                        Text("Device key: \(LobbyProtocol.fingerprint(member.id))")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(member.id == lobby.localIdentity ? "This device"
                             : (lobby.trustedName(member.id) != nil ? "Previously verified device key"
                                : "Unverified device. Verify its security code before joining a call."))
                            .font(.caption).foregroundStyle(.secondary)
                        if member.id != lobby.localIdentity,
                           let saved = lobby.trustedName(member.id), saved != member.name {
                            Text("Name when verified: \(saved)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(member.id == lobby.localIdentity ? "\(member.name) (you)" : member.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Label(member.state.label, systemImage: presenceIcon(member.state))
                                .font(.caption)
                                .foregroundStyle(member.state == .online ? Color.teal : .secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("groupMember-\(member.id)")
                    if member.id != lobby.localIdentity {
                        Button { callMember(member.id) } label: {
                            Image(systemName: "phone.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.borderless)
                        .tint(.teal)
                        .accessibilityLabel("Call \(member.name)")
                        .accessibilityIdentifier("callMember-\(member.id)")
                        .disabled(callBusy || lobby.waiting || lobby.sending || !lobby.online
                                  || !lobby.directCallsSupported
                                  || [.calling, .joining, .inCall].contains(member.state))
                    } else {
                        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 6)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] + 56 }
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
                Label(name, systemImage: "checkmark.shield.fill").font(.headline)
                Text("Previously verified device key").font(.caption).foregroundStyle(.secondary)
                if name != saved { Text("Verified originally as: \(saved)").font(.caption) }
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

private struct MemberAvatar: View {
    let identity: String
    let isYou: Bool
    @ObservedObject var photos: ProfilePhotoStore
    let remote: Data?

    private var tint: Color {
        let palette: [Color] = [.teal, .indigo, .blue, .purple, .orange]
        let index = identity.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return isYou ? .teal : palette[index]
    }

    var body: some View {
        ProfilePhotoCircle(data: isYou ? photos.photo : (remote ?? Data()), tint: tint,
                           symbol: isYou ? "iphone" : "person.fill")
    }
}

struct CallMediaIndicator: View {
    @ObservedObject var quality: CallQualityStore
    let connected: Bool
    var peer: String? = nil
    var details = false

    private func color(_ quality: CallQuality) -> Color {
        switch quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        default: return .secondary
        }
    }

    var body: some View {
        let indicator = quality.indicator(peer: peer, legacyConnected: connected)
        let path = peer.map { quality.path(peer: $0, legacyConnected: connected) }
        VStack(alignment: .leading, spacing: 6) {
            if details {
                Text(quality.snapshot.webRTC
                     ? "Audio transport from this iPhone. TURN/TLS is shown as TCP; the other phone's TURN connection may differ."
                     : "Legacy audio uses TCP. Quality measurements are unavailable.")
                if let peer, let reading = quality.snapshot.readings[peer],
                   ![.stale, .connecting].contains(indicator.quality) {
                    Text(metrics(reading.link))
                    Text("Estimated from recent network and audio statistics, not a guarantee of speech quality.")
                } else if quality.snapshot.webRTC {
                    Text("Measurements arrive about every 10 seconds after a roughly 20-second warm-up. Stale means no fresh report for 25 seconds.")
                }
            } else {
                Group {
                    if let peer, quality.snapshot.webRTC, !quality.snapshot.connected.contains(peer) {
                        Label("Connecting audio", systemImage: "waveform")
                            .foregroundStyle(.orange)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                transportBadge(indicator, path: path)
                                qualityBadge(indicator)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                transportBadge(indicator, path: path)
                                qualityBadge(indicator)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((path.map { "Audio path: \($0.description). " } ?? "")
                    + "Audio transport: \(indicator.transport.replacingOccurrences(of: "?", with: "Unknown")). Connection quality: \(indicator.qualityLabel).")
                .accessibilityIdentifier(peer.map { "mediaQuality-\($0)" } ?? "callMediaQuality")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .transaction { $0.animation = nil }
    }

    private func transportBadge(_ indicator: CallQualityIndicator, path: CallQualityStore.MediaPath?) -> some View {
        HStack(spacing: 10) {
            Label(indicator.transport, systemImage: "arrow.up.arrow.down")
            if let path {
                Label(path.rawValue, systemImage: path.symbol)
                    .help(path.description)
                    .accessibilityIdentifier("mediaPath-\(peer ?? "")")
            }
        }
    }

    private func qualityBadge(_ indicator: CallQualityIndicator) -> some View {
        Label(indicator.qualityLabel, systemImage: indicator.quality.symbol)
            .foregroundStyle(color(indicator.quality))
    }

    private func metrics(_ link: WebRTCQualityLink) -> String {
        func value(_ number: Double?, unit: String) -> String {
            guard let number, number.isFinite else { return "Unavailable" }
            return String(format: "%.1f", number) + unit
        }
        return "Path: \(path(link))\n"
            + "Round-trip: \(value(link.rttMs, unit: " ms"))\n"
            + "Jitter: \(value(link.jitterMs, unit: " ms"))\n"
            + "Packet loss (in / out): \(value(link.lossIn, unit: "%")) / \(value(link.lossOut, unit: "%"))\n"
            + "Concealed audio: \(value(link.conceal, unit: "%"))\n"
            + "Jitter buffer: \(value(link.jbMs, unit: " ms"))"
    }

    private func path(_ link: WebRTCQualityLink) -> String {
        let family = link.v6 == 1 ? " over IPv6" : ""
        switch link.relayed {
        case false?: return "Direct" + family
        case true?: return "Relayed through your TURN server" + family
        case nil: return "Unknown"
        }
    }
}

/// Shown during a call while iOS Local Network access is off. Calls between
/// phones on the same Wi-Fi then cannot connect directly.
struct LocalNetworkHint: View {
    @ObservedObject var access: LocalNetworkAccess
    @Environment(\.openURL) private var openURL

    var body: some View {
        if access.state == .denied {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Network is off for Canddle, so calls with phones on the same Wi-Fi go through your relay and have more delay.")
                Button("Turn On in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("localNetworkHint")
        }
    }
}
