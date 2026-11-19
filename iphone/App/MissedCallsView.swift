import SwiftUI
import UserNotifications

@MainActor
final class CallBadgeStore: ObservableObject {
    enum Permission { case unknown, notRequested, enabled, disabled }
    @Published private(set) var permission = Permission.unknown
    @Published private(set) var error: String?
    @Published private(set) var requesting = false
    private let history: MissedCallStore
    private var writer: Task<Void, Never>?
    private var revision = 0

    init(history: MissedCallStore) {
        self.history = history
        history.onChange = { [weak self] in self?.synchronize() }
    }

    func refresh() async {
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
        revision += 1
        guard writer == nil else { return }
        // Finish badge writes while handling a lock-screen call, and serialize them so clear wins.
        let background = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        writer = Task {
            defer {
                writer = nil
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            while true {
                let version = revision
                do {
                    try await UNUserNotificationCenter.current().setBadgeCount(history.count)
                    error = nil
                } catch {
                    self.error = "Icon badge unavailable. Missed calls are still saved here."
                }
                if version == revision { return }
            }
        }
    }
}

struct MissedCallsSection: View {
    @ObservedObject var history: MissedCallStore
    @ObservedObject var badge: CallBadgeStore

    var body: some View {
        if history.count > 0 {
            Section {
                DisclosureGroup {
                    ForEach(history.missed) { entry in
                        HStack {
                            Image(systemName: "phone.arrow.down.left.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(.body.weight(.semibold))
                                Text(entry.group ? "Missed group call" : "Missed call")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear missed calls", action: history.clear)
                        .accessibilityIdentifier("clearMissedCalls")
                } label: {
                    Label("Missed calls (\(history.count))", systemImage: "phone.badge.waveform")
                        .foregroundStyle(.red)
                }
                BadgePermissionView(badge: badge)
            }
            .accessibilityIdentifier("missedCalls")
        }
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
