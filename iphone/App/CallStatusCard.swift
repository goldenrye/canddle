import SwiftUI

struct CallStatusCard: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore
    let configured: Bool

    private var phase: CallPhase {
        lobby.callPhase(configured: configured, audioBusy: call.busy,
                        audioConnected: call.connected, pairing: call.pairing)
    }

    private var tint: Color {
        phase.needsAction || phase == .recovering ? .orange : .teal
    }

    private var displayedCaller: LobbyOffer? {
        if let joining = lobby.joining, !lobby.inCall { return joining.offer }
        return phase == .incoming ? lobby.incomingOffer : nil
    }

    private var context: String {
        if let offer = displayedCaller {
            return offer.callerDisplayName(verified: lobby.trustedName(offer.identity) != nil)
        }
        guard phase.isCall else { return "You: \(lobby.name)" }
        if let target = lobby.ownOffer?.target {
            return lobby.groupDirectory.first { $0.id == target }?.name
                ?? lobby.trustedName(target) ?? "Selected member"
        }
        if lobby.isIndividual, let joining = lobby.joining { return joining.offer.name }
        if lobby.inCall { return "Group call (\(lobby.members.count) participants)" }
        return lobby.waiting ? "Group call" : "Private call"
    }

    private var title: String {
        if phase == .incoming, displayedCaller?.target == nil { return "Group call invitation" }
        return phase == .calling && !lobby.isIndividual ? "Waiting for members" : phase.title
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let offer = displayedCaller {
                            ProfilePhotoCircle(
                                data: lobby.memberPhoto(offer.identity, in: lobby.relayScope), size: 44)
                        } else {
                            Image("BrandLogo").resizable().scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                        .overlay(alignment: .bottomTrailing) {
                            if phase.isCall {
                                Image(systemName: phase.symbol)
                                    .font(.caption2.weight(.semibold)).foregroundStyle(tint)
                                    .frame(width: 24, height: 24)
                                    .background(.background, in: Circle())
                                    .offset(x: 5, y: 5)
                            }
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("callContext")
                        Text(title).font(.title3.weight(.bold))
                            .foregroundStyle(phase.needsAction ? tint : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("callPhase")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Keep actionable errors visible, rather than hiding store messages in diagnostics.
                Text(lobby.recoveringMedia ? lobby.status : (call.busy ? call.status : lobby.status))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lobbyStatus")

                if let stage = phase.stage, phase != .connected {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { stages(stage) }
                        VStack(alignment: .leading, spacing: 8) { stages(stage) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(stage == 3 ? "Invitation, approval and audio connected"
                        : "Call progress: \(["Invitation", "Approval", "Audio connection"][stage])")
                    if phase == .incoming {
                        Text(displayedCaller?.target == nil
                             ? "Join the group invitation below. The caller's name and photo do not replace device verification."
                             : "Answer or decline below. The caller's name and photo do not replace device verification.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if phase == .calling {
                        Text(lobby.isIndividual
                             ? "Calling this member only. A dialing tone does not confirm their phone is ringing."
                             : "Members can request to join. Review their requests below before audio starts.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if phase == .peerVerification {
                        Text("Waiting for the other person to confirm your identity. Your Accept button becomes available after they confirm.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if phase.needsAction {
                        Label("Review the security check below to continue.", systemImage: "arrow.down")
                            .font(.subheadline.weight(.medium)).foregroundStyle(tint)
                    }
                }
                if lobby.inCall || (call.busy && !call.pairing) {
                    DisclosureGroup("Connection details") {
                        CallMediaIndicator(quality: call.mediaQuality, connected: call.connected)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("callConnectionDetails")
                    LocalNetworkHint(access: call.localNetwork)
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(
                LinearGradient(colors: [Color(.secondarySystemGroupedBackground), tint.opacity(0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .onChange(of: phase) { next in
            if next.isCall { UIAccessibility.post(notification: .announcement, argument: title) }
        }
    }

    @ViewBuilder
    private func stages(_ active: Int) -> some View {
        ForEach(Array(["Invite", "Approval", "Audio"].enumerated()), id: \.offset) { index, label in
            Label(label, systemImage: index < active ? "checkmark.circle.fill" : "\(index + 1).circle")
                .font(.caption.weight(index == active ? .semibold : .regular))
                .foregroundStyle(index <= active ? tint : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(index == active ? tint.opacity(0.12) : Color(.tertiarySystemFill),
                            in: Capsule())
        }
    }
}
