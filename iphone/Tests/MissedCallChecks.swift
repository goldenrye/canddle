import CryptoKit
import Foundation

@main struct MissedCallChecks {
    @MainActor static func main() async throws {
        let suite = "canddle.missed-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MissedCallStore(defaults: defaults)
        let scope = "wss://test.example/relay"
        let caller = Curve25519.Signing.PrivateKey()
        let recipient = VoiceProtocol.base64(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        func offer(group: Bool = false) throws -> LobbyOffer {
            try LobbyOffer.create(identity: caller, name: "Family", ephemeral: .init(),
                                  target: group ? nil : recipient)
        }
        let first = try offer()
        precondition(first.callerDisplayName(verified: true) == "Family")
        precondition(first.callerDisplayName(verified: false) == "Family (unverified)")
        let renamed = try LobbyOffer.create(identity: caller, name: "Alice", ephemeral: .init(),
                                            target: recipient)
        precondition(renamed.identity == first.identity)
        precondition(renamed.callerDisplayName(verified: true) == "Alice",
                     "A previously verified key must display its latest signed name")
        var changes = 0
        store.onChange = { changes += 1 }
        store.receive(first, scope: scope, name: first.name)
        store.receive(first, scope: scope, name: first.name) // Push and socket describe one call.
        precondition(store.count == 0 && store.entries.count == 1 && changes == 1)
        precondition(store.isRinging(first.id, scope: scope))
        store.closed(first.id, scope: "wss://other.example")
        store.closed("unknown", scope: scope)
        precondition(store.count == 0)
        store.closed(first.id, scope: scope) // Remote end or unanswered deadline.
        store.closed(first.id, scope: scope)
        precondition(store.count == 1 && changes == 2)
        let loaded = MissedCallStore(defaults: defaults)
        precondition(loaded.count == 1 && loaded.missed[0].caller == first.identity)
        loaded.clear()
        loaded.receive(first, scope: scope, name: first.name)
        loaded.closed(first.id, scope: scope)
        precondition(loaded.count == 0)
        precondition(MissedCallStore(defaults: defaults).count == 0)
        for group in [false, true] {
            for _ in 0..<2 { // Answer and decline both explicitly handle an invitation.
                let answered = try offer(group: group)
                loaded.receive(answered, scope: scope, name: answered.name)
                loaded.handled(answered.id, scope: scope)
                loaded.closed(answered.id, scope: scope)
                precondition(loaded.count == 0)
            }
        }
        let group = try offer(group: true)
        loaded.receive(group, scope: scope, name: group.name)
        precondition(MissedCallStore(defaults: defaults).count == 0) // Relaunch is not proof of a miss.
        loaded.closed(group.id, scope: scope)
        precondition(loaded.count == 1 && loaded.missed[0].group)
        loaded.handled(group.id, scope: scope) // In-app join after the system ringing deadline.
        precondition(loaded.count == 0)

        let payload: [AnyHashable: Any] = [
            "v": 1, "scope": scope, "recipient": recipient, "expires": 1030.0, "offer": first.message
        ]
        let verified = try IncomingCallPush(payload, scope: scope, recipient: recipient, now: 1000).offer
        precondition(verified.id == first.id)
        for field in ["scope", "recipient", "expires", "offer"] {
            var invalid = payload
            if field == "expires" { invalid[field] = 999.0 }
            else if field == "offer" {
                var forged = first.message
                forged["name"] = "Forged"
                invalid[field] = forged
            } else { invalid[field] = "wrong" }
            do {
                let untrusted = try IncomingCallPush(invalid, scope: scope, recipient: recipient, now: 1000)
                loaded.receive(untrusted.offer, scope: scope, name: "Must not happen")
                preconditionFailure("Invalid incoming push accepted")
            } catch {}
        }
        precondition(loaded.count == 0)
        for _ in 0..<140 {
            let next = try offer()
            loaded.receive(next, scope: scope, name: next.name)
            loaded.closed(next.id, scope: scope)
        }
        precondition(loaded.count == 128 && loaded.entries.count == 128)
        precondition(MissedCallStore(defaults: defaults).count == 128)
        loaded.forget()
        precondition(MissedCallStore(defaults: defaults).entries.isEmpty)

        var now = Date(timeIntervalSince1970: 1000)
        let timed = MissedCallStore(defaults: defaults, automaticallyExpire: false, clock: { now })
        let pending = try offer()
        timed.receive(pending, scope: scope, name: pending.name)
        precondition(timed.badgeUpdates().first?.date == now.addingTimeInterval(120))
        now.addTimeInterval(10)
        timed.receive(pending, scope: scope, name: pending.name, timeout: 30)
        let shortened = timed.badgeUpdates()[0]
        precondition(shortened.date == Date(timeIntervalSince1970: 1040) && shortened.count == 1)
        now.addTimeInterval(10)
        timed.receive(pending, scope: scope, name: pending.name, timeout: 30)
        precondition(timed.badgeUpdates()[0] == shortened, "Duplicate push cannot restart ringing")
        now.addTimeInterval(21)
        // No closed event and no live Task: a fresh process must recover the expired invitation.
        let resumed = MissedCallStore(defaults: defaults, automaticallyExpire: false, clock: { now })
        precondition(resumed.count == 1 && resumed.badgeUpdates().isEmpty)
        precondition(resumed.missed[0].date == shortened.date)
        resumed.declined(pending.id, scope: scope)
        precondition(resumed.count == 1, "A late system end cannot erase a timeout")
        resumed.clear()
        resumed.closed(pending.id, scope: scope)
        precondition(resumed.count == 0)
        resumed.forget()

        let afterSuspension = try offer()
        resumed.receive(afterSuspension, scope: scope, name: afterSuspension.name, timeout: 30)
        now.addTimeInterval(31)
        resumed.reconcile()
        precondition(resumed.count == 1)
        resumed.handled(afterSuspension.id, scope: scope)
        precondition(resumed.count == 0, "An actual late answer may clear the missed invitation")
        resumed.forget()

        let sameTimeA = try offer(), sameTimeB = try offer()
        resumed.receive(sameTimeA, scope: scope, name: sameTimeA.name, timeout: 30)
        resumed.receive(sameTimeB, scope: scope, name: sameTimeB.name, timeout: 30)
        precondition(resumed.badgeUpdates().allSatisfy { $0.count == 2 })
        resumed.declined(sameTimeA.id, scope: scope)
        precondition(resumed.badgeUpdates().count == 1 && resumed.badgeUpdates()[0].count == 1)
        resumed.handled(sameTimeB.id, scope: scope)
        now.addTimeInterval(31)
        resumed.reconcile()
        precondition(resumed.count == 0 && resumed.badgeUpdates().isEmpty)
        resumed.forget()

        // Migrate records from the original journal, which had no durable ringing deadline.
        let old = MissedCallStore.Entry(scope: scope, call: first.id, caller: first.identity,
            name: first.name, group: false, date: now.addingTimeInterval(-121),
            outcome: .ringing, deadline: nil)
        defaults.set(try JSONEncoder().encode([old]), forKey: "missedCalls.v1")
        let migrated = MissedCallStore(defaults: defaults, automaticallyExpire: false, clock: { now })
        precondition(migrated.count == 1)
        migrated.forget()

        for action in ["answer", "decline", "clear"] {
            let journal = MissedCallStore(defaults: defaults, automaticallyExpire: false)
            var writes: [(Int, [MissedCallStore.BadgeUpdate])] = []
            var gate: CheckedContinuation<Void, Never>?
            let synchronizer = MissedCallBadgeSync(history: journal, write: { count, updates in
                writes.append((count, updates))
                if writes.count == 1 { await withCheckedContinuation { gate = $0 } }
            })
            journal.onChange = { [weak synchronizer] in synchronizer?.synchronize() }
            let invitation = try offer()
            journal.receive(invitation, scope: scope, name: invitation.name, timeout: 30)
            let limit = Date().addingTimeInterval(2)
            while gate == nil {
                precondition(Date() < limit)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            precondition(writes[0].1.count == 1)
            if action == "answer" { journal.handled(invitation.id, scope: scope) }
            else if action == "decline" { journal.declined(invitation.id, scope: scope) }
            else {
                journal.closed(invitation.id, scope: scope)
                journal.clear()
            }
            gate?.resume()
            await synchronizer.flush()
            precondition(writes.count == 2 && writes.last!.0 == 0 && writes.last!.1.isEmpty,
                         "The latest state must cancel an older scheduled badge after \(action)")
            journal.onChange = nil
            journal.forget()
        }

        let automatic = MissedCallStore(defaults: defaults)
        let unanswered = try offer()
        automatic.receive(unanswered, scope: scope, name: unanswered.name, timeout: 1)
        let until = Date().addingTimeInterval(3)
        while automatic.count == 0 {
            precondition(Date() < until, "Unanswered timer failed without a relay close")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(automatic.badgeUpdates().isEmpty)
        automatic.forget()
        print("PASS missed calls: expiry without close, suspension/relaunch, migration, duplicate deadlines, answer/decline, serialized badge cancellation, bounds and push validation")
    }
}
