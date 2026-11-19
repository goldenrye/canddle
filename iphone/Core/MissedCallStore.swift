import Combine
import Foundation

/// Only authenticated incoming offers enter this journal. Transport loss alone is not a miss.
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
        var id: String { scope + "|" + call }
    }

    private static let key = "missedCalls.v1"
    private let defaults: UserDefaults
    @Published private(set) var entries: [Entry] = []
    var onChange: (() -> Void)?
    var missed: [Entry] { entries.filter { $0.outcome == .missed }.reversed() }
    var count: Int { missed.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 256_000,
           let saved = try? JSONDecoder().decode([Entry].self, from: data),
           saved.count <= 128, Set(saved.map(\.id)).count == saved.count {
            entries = saved
        }
    }

    func receive(_ offer: LobbyOffer, scope: String, name: String, now: Date = Date()) {
        guard !scope.isEmpty, !entries.contains(where: { $0.scope == scope && $0.call == offer.id }) else { return }
        entries.append(Entry(scope: scope, call: offer.id, caller: offer.identity,
                             name: String(name.prefix(80)), group: offer.target == nil,
                             date: now, outcome: .ringing))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        save()
    }

    func handled(_ call: String, scope: String) {
        transition(call, scope: scope, to: .handled)
    }

    func isRinging(_ call: String, scope: String) -> Bool {
        entries.contains { $0.scope == scope && $0.call == call && $0.outcome == .ringing }
    }

    func closed(_ call: String, scope: String) {
        transition(call, scope: scope, to: .missed)
    }

    private func transition(_ call: String, scope: String, to outcome: Entry.Outcome) {
        guard let index = entries.firstIndex(where: { $0.scope == scope && $0.call == call }),
              entries[index].outcome == .ringing
                || (outcome == .handled && entries[index].outcome == .missed) else { return }
        entries[index].outcome = outcome
        if outcome == .missed { entries[index].date = Date() }
        save()
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
        defaults.removeObject(forKey: Self.key)
        onChange?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        onChange?()
    }
}
