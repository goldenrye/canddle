import CryptoKit
import Foundation

@main struct MissedCallChecks {
    @MainActor static func main() throws {
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
        print("PASS missed-call deduplication, handling, clearing, persistence, bounds and push validation")
    }
}
