import Combine
import CryptoKit
import Foundation

/// Only authenticated incoming offers enter this journal. Unanswered deadlines survive suspension.
@MainActor
final class MissedCallStore: ObservableObject {
    struct Entry: Codable, Identifiable {
        enum Outcome: String, Codable { case ringing, handled, missed, reviewed }
        let scope: String
        let call: String
        let caller: String
        let name: String
        let group: Bool
        var date: Date
        var outcome: Outcome
        var deadline: Date?
        var id: String { scope + "|" + call }
        var expires: Date { deadline ?? date.addingTimeInterval(120) }
        var notificationID: String {
            "canddle.missed." + SHA256.hash(data: Data(id.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    struct BadgeUpdate: Equatable {
        let id: String
        let date: Date
        let count: Int
    }

    private static let key = "missedCalls.v1"
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let automaticallyExpire: Bool
    private var wakeup: Task<Void, Never>?
    @Published private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?
    var missed: [Entry] { entries.filter { $0.outcome == .missed }.reversed() }
    var count: Int { missed.count }

    init(defaults: UserDefaults = .standard, automaticallyExpire: Bool = true,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        self.automaticallyExpire = automaticallyExpire
        if let data = defaults.data(forKey: Self.key), data.count <= 256_000,
           let saved = try? JSONDecoder().decode([Entry].self, from: data),
           saved.count <= 128, Set(saved.map(\.id)).count == saved.count {
            entries = saved
        }
        reconcile()
    }

    func receive(_ offer: LobbyOffer, scope: String, name: String, now: Date? = nil,
                 timeout: TimeInterval = 120) {
        guard !scope.isEmpty else { return }
        let now = now ?? clock()
        let deadline = now.addingTimeInterval(min(120, max(1, timeout)))
        if let index = entries.firstIndex(where: { $0.scope == scope && $0.call == offer.id }) {
            // A push can shorten a socket invitation's deadline, but duplicates cannot extend it.
            if entries[index].outcome == .ringing, deadline < entries[index].expires {
                entries[index].deadline = deadline
                save()
            }
            return
        }
        entries.append(Entry(scope: scope, call: offer.id, caller: offer.identity,
                             name: String(name.prefix(80)), group: offer.target == nil,
                             date: now, outcome: .ringing, deadline: deadline))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        save()
    }

    func handled(_ call: String, scope: String) {
        transition(call, scope: scope, to: .handled)
    }

    func declined(_ call: String, scope: String) {
        // A late system end callback must not erase a call that already timed out.
        reconcile()
        transition(call, scope: scope, to: .handled, allowMissed: false)
    }

    func isRinging(_ call: String, scope: String) -> Bool {
        entries.contains { $0.scope == scope && $0.call == call && $0.outcome == .ringing }
    }

    func closed(_ call: String, scope: String) {
        transition(call, scope: scope, to: .missed)
    }

    private func transition(_ call: String, scope: String, to outcome: Entry.Outcome,
                            allowMissed: Bool = true) {
        guard let index = entries.firstIndex(where: { $0.scope == scope && $0.call == call }),
              entries[index].outcome == .ringing
                || (allowMissed && outcome == .handled && entries[index].outcome == .missed) else { return }
        entries[index].outcome = outcome
        if outcome == .missed { entries[index].date = clock() }
        save()
    }

    func reconcile(now: Date? = nil) {
        let now = now ?? clock()
        var updated = entries
        var changed = false
        for index in updated.indices where updated[index].outcome == .ringing && updated[index].expires <= now {
            updated[index].date = updated[index].expires
            updated[index].outcome = .missed
            changed = true
        }
        if changed {
            entries = updated
            save()
        } else {
            scheduleWakeup()
        }
    }

    /// Silent local notifications let iOS update the badge even when this process is suspended.
    func badgeUpdates() -> [BadgeUpdate] {
        let ringing = entries.filter { $0.outcome == .ringing }.sorted { $0.expires < $1.expires }
        return ringing.prefix(32).map { entry in
            BadgeUpdate(id: entry.notificationID, date: entry.expires,
                        count: count + ringing.filter { $0.expires <= entry.expires }.count)
        }
    }

    func clear() {
        // Keep deduplication receipts so a repeated close/push cannot restore a cleared badge.
        for index in entries.indices where entries[index].outcome == .missed {
            entries[index].outcome = .reviewed
        }
        save()
    }

    func forget() {
        entries = []
        wakeup?.cancel()
        wakeup = nil
        defaults.removeObject(forKey: Self.key)
        onChange?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        scheduleWakeup()
        onChange?()
    }

    private func scheduleWakeup() {
        wakeup?.cancel()
        wakeup = nil
        guard automaticallyExpire,
              let deadline = entries.filter({ $0.outcome == .ringing }).map(\.expires).min() else { return }
        let delay = max(0, min(120, deadline.timeIntervalSince(clock())))
        wakeup = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.reconcile()
            } catch {}
        }
    }
}

/// Serializes OS writes; an answer/clear that arrives during an older write always wins.
@MainActor
final class MissedCallBadgeSync {
    private let history: MissedCallStore
    private let additionalCount: () -> Int
    private let write: (Int, [MissedCallStore.BadgeUpdate]) async throws -> Void
    private let report: (Error?) -> Void
    private let finished: () -> Void
    private var writer: Task<Void, Never>?
    private var revision = 0

    init(history: MissedCallStore,
         additionalCount: @escaping () -> Int = { 0 },
         write: @escaping (Int, [MissedCallStore.BadgeUpdate]) async throws -> Void,
         report: @escaping (Error?) -> Void = { _ in },
         finished: @escaping () -> Void = {}) {
        self.history = history
        self.additionalCount = additionalCount
        self.write = write
        self.report = report
        self.finished = finished
    }

    func synchronize() {
        revision += 1
        guard writer == nil else { return }
        writer = Task {
            defer { writer = nil; finished() }
            while true {
                let version = revision
                do {
                    let extra = max(0, additionalCount())
                    let updates = history.badgeUpdates().map {
                        MissedCallStore.BadgeUpdate(id: $0.id, date: $0.date, count: $0.count + extra)
                    }
                    try await write(history.count + extra, updates)
                    report(nil)
                } catch { report(error) }
                if version == revision { return }
            }
        }
    }

    func flush() async { await writer?.value }
}
