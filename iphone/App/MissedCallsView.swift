import SwiftUI
import UserNotifications

@MainActor
final class CallBadgeStore: ObservableObject {
    enum Permission { case unknown, notRequested, enabled, disabled }
    @Published private(set) var permission = Permission.unknown
    @Published private(set) var error: String?
    @Published private(set) var requesting = false
    private let history: MissedCallStore
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private lazy var synchronizer = MissedCallBadgeSync(history: history, write: { count, updates in
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers:
            pending.map(\.identifier).filter { $0.hasPrefix("canddle.missed.") })
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers:
            delivered.map(\.request.identifier).filter { $0.hasPrefix("canddle.missed.") })
        try await center.setBadgeCount(count)
        let settings = await center.notificationSettings()
        guard settings.badgeSetting == .enabled else { return }
        for update in updates {
            let content = UNMutableNotificationContent()
            content.badge = NSNumber(value: update.count)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, update.date.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(
                identifier: update.id, content: content, trigger: trigger))
        }
    }, report: { [weak self] error in
        self?.error = error == nil ? nil : "Icon badge unavailable. Missed calls are still saved here."
    }, finished: { [weak self] in
        self?.releaseBackgroundTask()
    })

    init(history: MissedCallStore) {
        self.history = history
        history.onChange = { [weak self] in self?.synchronize() }
    }

    func refresh() async {
        history.reconcile()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            permission = .notRequested
        } else {
            permission = settings.badgeSetting == .enabled ? .enabled : .disabled
        }
        synchronize()
    }

    func request() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
            await refresh()
        } catch { self.error = "Could not request badge access. Check iPhone Settings." }
    }

    func synchronize() {
        // Reserve time synchronously, before CallKit teardown can end its background task.
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                Task { @MainActor in self?.releaseBackgroundTask() }
            }
        }
        synchronizer.synchronize()
    }

    private func releaseBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

struct MissedCallsSection: View {
    @ObservedObject var history: MissedCallStore
    @ObservedObject var badge: CallBadgeStore
    @ObservedObject var lobby: GroupStore
    @ObservedObject var call: CallStore

    var body: some View {
        if history.count > 0 {
            Section {
                DisclosureGroup {
                    ForEach(history.missed) { entry in
                        HStack(spacing: 12) {
                            callerPhoto(entry)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(.body.weight(.semibold))
                                Label(entry.group ? "Missed group call" : "Missed call",
                                      systemImage: "phone.arrow.down.left.fill")
                                    .font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            Button { call.callBack(entry) } label: {
                                Image(systemName: "phone.fill")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)
                            .tint(.teal)
                            .accessibilityLabel("Call back \(entry.name)")
                            .accessibilityHint("Start a private Canddle call to this caller.")
                            .accessibilityIdentifier("callBack-\(entry.call)")
                            .disabled(!call.canCallBack(entry))
                        }
                    }
                    Button("Clear missed calls", action: history.clear)
                        .accessibilityIdentifier("clearMissedCalls")
                } label: {
                    HStack(spacing: 12) {
                        if let latest = history.missed.first { callerPhoto(latest) }
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Missed calls (\(history.count))", systemImage: "phone.badge.waveform")
                                .foregroundStyle(.red)
                            if let latest = history.missed.first {
                                Text(latest.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                BadgePermissionView(badge: badge)
            }
            .accessibilityIdentifier("missedCalls")
        } else if badge.permission == .notRequested || badge.permission == .disabled {
            Section {
                BadgePermissionView(badge: badge)
                Text("Allow badges to see missed calls on the Canddle icon. Calls are still saved here without permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func callerPhoto(_ entry: MissedCallStore.Entry) -> some View {
        ProfilePhotoCircle(data: lobby.memberPhoto(entry.caller, in: entry.scope), size: 40)
    }
}

struct BadgePermissionView: View {
    @ObservedObject var badge: CallBadgeStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch badge.permission {
        case .unknown:
            EmptyView()
        case .notRequested:
            Button("Enable missed-call icon badge") { Task { await badge.request() } }
                .disabled(badge.requesting)
                .accessibilityIdentifier("requestCallBadge")
        case .disabled:
            Button("Enable Badges in iPhone Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("callBadgeSettings")
        case .enabled:
            Label("Missed-call icon badge enabled", systemImage: "app.badge")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("callBadgeEnabled")
        }
        if let error = badge.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }
}
