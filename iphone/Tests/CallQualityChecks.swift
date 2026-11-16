import Combine
import Foundation

@main
struct CallQualityChecks {
    @MainActor static func main() async throws {
        let quality = CallQualityStore()
        var changes = 0
        let subscription = quality.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        quality.reset()
        precondition(changes == 0)
        quality.start(peers: ["alice", "bob"])
        precondition(changes == 1)
        quality.setPeers(["bob", "alice"])
        quality.setConnected([])
        quality.receive([])
        precondition(changes == 1, "Unchanged state must not redraw observers")
        quality.setConnected(["alice", "bob"])
        precondition(changes == 2)

        var old = WebRTCQualitySample()
        old.seconds = 10
        var new = old
        new.seconds = 20
        new.route = "host/udp>host/udp"
        new.roundTrip = 0.1
        new.jitter = 0.01
        new.packetsReceived = 500
        new.totalSamplesReceived = 480_000
        let alice = WebRTCQualityLink(peer: "alice", from: old, to: new, muted: false)!
        var bob = alice
        bob.to = "bob"
        bob.route = "relay/tcp>host/udp"
        let now = Date()
        quality.receive([alice, bob], at: now)
        precondition(changes == 3, "A group sample should publish once, not once per peer")
        precondition(quality.indicator(legacyConnected: true).quality == .good)
        precondition(quality.indicator(legacyConnected: true).transport == "TCP / UDP")
        quality.receive([alice, bob], at: now)
        precondition(changes == 3)
        quality.expire(at: now.addingTimeInterval(25))
        precondition(changes == 3)
        quality.expire(at: now.addingTimeInterval(26))
        precondition(changes == 4 && quality.snapshot.stale == ["alice", "bob"])
        precondition(quality.indicator(legacyConnected: true).quality == .stale)
        quality.expire(at: now.addingTimeInterval(27))
        precondition(changes == 4, "Already stale readings should not keep publishing")
        quality.receive([alice], at: now)
        precondition(quality.snapshot.stale == ["bob"])
        quality.setConnected(["bob"])
        precondition(quality.snapshot.readings["alice"] == nil)
        quality.setConnected(["alice", "bob"])
        precondition(quality.indicator(peer: "alice", legacyConnected: true).quality == .measuring)
        quality.setPeers(["alice"])
        precondition(quality.snapshot.readings.isEmpty && quality.snapshot.stale.isEmpty)
        quality.receive([bob], at: now)
        precondition(quality.snapshot.readings.isEmpty, "Removed peers cannot restore cached readings")
        quality.start(peers: ["alice"])
        precondition(quality.snapshot.connected.isEmpty)
        quality.reset()
        precondition(!quality.snapshot.webRTC && quality.snapshot.readings.isEmpty)
        precondition(quality.indicator(legacyConnected: true).quality == .unavailable)

        // Exercise the real one-shot expiry and cancellation without a 25s wait.
        quality.start(peers: ["alice"])
        quality.setConnected(["alice"])
        quality.receive([alice], at: Date().addingTimeInterval(-26))
        let expired = quality.$snapshot.values
        for await snapshot in expired where snapshot.stale.contains("alice") { break }
        precondition(quality.indicator(legacyConnected: true).quality == .stale)
        quality.receive([alice], at: Date().addingTimeInterval(-26))
        quality.reset()
        // Give the canceled expiry an opportunity to run; it must not resurrect state.
        for _ in 0..<10 { await Task.yield() }
        precondition(quality.snapshot == CallQualityStore.Snapshot())
        print("PASS: batched quality updates, unchanged-state suppression, expiry, reconnect and teardown")
    }
}
