import SwiftUI
import UserNotifications

@MainActor
private final class MessageViewState: ObservableObject {
    @Published var note = ""
    @Published var draft = ""
}

struct MessageInboxButton: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore
    @ObservedObject var messages: MessageStore

    var body: some View {
        Button { messages.showInbox = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.bubble.right").frame(width: 40, height: 36)
                if messages.unreadCount > 0 {
                    Text(messages.unreadCount > 99 ? "99+" : "\(messages.unreadCount)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.red, in: Capsule())
                }
            }
        }
        .accessibilityLabel("Messages, \(messages.unreadCount) unread")
        .accessibilityIdentifier("messages")
        .sheet(isPresented: $messages.showInbox) {
            MessageInbox(call: call, lobby: lobby, messages: messages)
        }
        .onChange(of: call.busy) { if $0 { messages.showInbox = false } }
        .onChange(of: lobby.waiting) { if $0 { messages.showInbox = false } }
    }
}

private struct MessageInbox: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore
    @ObservedObject var messages: MessageStore
    @Environment(\.scenePhase) private var phase

    private var peers: [String] {
        let current = lobby.relayScope == messages.scope
            ? lobby.groupDirectory.filter { lobby.trustedName($0.id) != nil }.map(\.id) : []
        return Set(current + messages.entries.map(\.peer)).sorted {
            name($0).localizedStandardCompare(name($1)) == .orderedAscending
        }
    }

    private func name(_ peer: String) -> String {
        guard messages.scope == lobby.relayScope else { return "Saved device \(LobbyProtocol.fingerprint(peer).prefix(8))" }
        return lobby.groupDirectory.first { $0.id == peer }?.name
            ?? lobby.trustedName(peer) ?? "Unverified device"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(messages.status, systemImage: messages.online ? "lock.shield" : "wifi.slash")
                        .font(.subheadline)
                    if let error = messages.error { Text(error).font(.caption).foregroundStyle(.red) }
                    MessageNotificationSettings(messages: messages, badge: call.callBadge)
                    BadgePermissionView(badge: call.callBadge)
                } footer: {
                    Text("Only previously verified devices can exchange private text. Open Canddle on both phones after upgrading. Pending messages retry when connected; offline delivery expires after seven days.")
                }
                if peers.isEmpty {
                    Section {
                        Text("No verified conversations yet")
                            .font(.headline)
                        Text("Complete device verification during a call, then return here to message that member.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Conversations") {
                        ForEach(peers, id: \.self) { peer in
                            NavigationLink {
                                ConversationView(call: call, lobby: lobby, messages: messages,
                                                 history: call.missedCalls, peer: peer, name: name(peer))
                            } label: {
                                HStack(spacing: 12) {
                                    ProfilePhotoCircle(data: lobby.memberPhoto(peer, in: messages.scope), size: 40)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name(peer)).font(.headline)
                                        if let last = messages.entries.last(where: { $0.peer == peer }) {
                                            Text(last.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        } else { Text("Start a private conversation").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    let unread = messages.entries.filter { $0.peer == peer && $0.unread }.count
                                    if unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(.teal) }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                if lobby.incomingOffer != nil {
                    Button("Incoming call: return to Calls") { messages.showInbox = false }
                }
            }
            .navigationTitle("Messages")
            .toolbar { Button("Done") { messages.showInbox = false } }
            .tint(.teal)
        }
        .overlay {
            if phase != .active {
                Color(.systemBackground).ignoresSafeArea()
                    .overlay { Text("Canddle").font(.title) }
            }
        }
    }
}

private struct MessageNotificationSettings: View {
    @ObservedObject var messages: MessageStore
    @ObservedObject var badge: CallBadgeStore
    @StateObject private var state = MessageViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Enable message notifications") {
                Task {
                    do {
                        _ = try await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge])
                        UIApplication.shared.registerForRemoteNotifications()
                        await badge.refresh()
                        let settings = await UNUserNotificationCenter.current().notificationSettings()
                        state.note = settings.alertSetting == .enabled
                            ? "Alerts enabled on this iPhone."
                            : "Enable Alerts for Canddle in iPhone Settings."
                    } catch { state.note = "Could not request notification permission." }
                }
            }
            Button("Open iPhone notification settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.font(.caption)
            if !state.note.isEmpty { Text(state.note).font(.caption).foregroundStyle(.secondary) }
            if let error = messages.notificationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if !messages.pushAvailable {
                Text("The relay must also have Apple push configured for background alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConversationView: View {
    @ObservedObject var call: CallStore
    @ObservedObject var lobby: GroupStore
    @ObservedObject var messages: MessageStore
    @ObservedObject var history: MissedCallStore
    let peer: String
    let name: String
    @StateObject private var state = MessageViewState()
    @Environment(\.scenePhase) private var phase

    private struct Event: Identifiable {
        let id: String
        let date: Date
        let entry: MessageStore.Entry?
    }
    private var events: [Event] {
        (messages.entries.filter { $0.peer == peer }.map {
            Event(id: "\($0.outgoing)-\($0.id)", date: $0.date, entry: $0)
        } + history.missed.filter { $0.scope == messages.scope && $0.caller == peer }.map {
            Event(id: "call-\($0.id)", date: $0.date, entry: nil)
        }).sorted { $0.date < $1.date }
    }
    private var verified: Bool {
        messages.scope == lobby.relayScope && lobby.trustedName(peer) != nil
    }
    private var canCall: Bool {
        verified && lobby.online && lobby.directCallsSupported && !lobby.waiting
            && !call.busy && !call.systemCalls.hasCall && !lobby.sending
            && ![GroupPresenceState.calling, .joining, .inCall].contains(lobby.presence[peer]?.state ?? .unknown)
    }

    var body: some View {
        ScrollViewReader { conversation(proxy: $0) }
    }

    private func conversation(proxy: ScrollViewProxy) -> some View {
        List {
            if !verified { Text("Verify this device in a call before sending messages.").foregroundStyle(.orange) }
            if let error = messages.error { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(events) { event in
                if let entry = event.entry {
                    HStack {
                        if entry.outgoing { Spacer(minLength: 30) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.text).textSelection(.enabled)
                            HStack {
                                Text(entry.date, style: .time)
                                if entry.outgoing {
                                    Text(entry.state == .queued ? "Queued for delivery" : entry.state.rawValue.capitalized)
                                }
                            }.font(.caption2).foregroundStyle(.secondary)
                            if entry.outgoing && entry.state == .failed {
                                Button("Retry") { messages.retry(entry) }.font(.caption)
                            }
                        }
                        .padding(12)
                        .background(entry.outgoing ? Color.teal.opacity(0.12) : Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14))
                        if !entry.outgoing { Spacer(minLength: 30) }
                    }
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                } else {
                    Label {
                        Text("Missed call") + Text(" · ") + Text(event.date, style: .date)
                    } icon: { Image(systemName: "phone.arrow.down.left.fill") }
                    .font(.caption).foregroundStyle(.red)
                }
            }
            if lobby.incomingOffer != nil {
                Button("Incoming call: return to Calls") { messages.showInbox = false }
            }
        }
        .listStyle(.plain)
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    guard canCall else { return }
                    messages.showInbox = false
                    call.openLobby(startCall: true, target: peer)
                } label: { Image(systemName: "phone.fill") }
                .accessibilityLabel("Call \(name)").disabled(!canCall)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Clear read history", role: .destructive) { messages.clearReadHistory(peer) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Private message", text: $state.draft, axis: .vertical).lineLimit(1...5)
                    .padding(10).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    let count = messages.entries.count
                    messages.send(state.draft, to: peer)
                    if messages.entries.count > count { state.draft = "" }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Send message")
                .disabled(!verified || !messages.supported || state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || state.draft.utf8.count > 4096)
            }.padding().background(.regularMaterial)
        }
        .onAppear {
            messages.selectedPeer = peer
            messages.markRead(peer)
            if let last = events.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        .onChange(of: events.last?.id) { id in
            if let id { proxy.scrollTo(id, anchor: .bottom) }
        }
        .onDisappear { if messages.selectedPeer == peer { messages.selectedPeer = nil } }
        .onChange(of: phase) {
            messages.selectedPeer = $0 == .active ? peer : nil
            if $0 == .active { messages.markRead(peer) }
        }
    }
}
