import Combine
import Foundation

/// Observed only by media badges/details, never by the whole call screen.
@MainActor
final class CallQualityStore: ObservableObject {
    enum MediaPath: String {
        case direct = "Direct", turn = "TURN", relay = "Relay", unknown = "Path ?"

        var symbol: String {
            switch self {
            case .direct: return "arrow.left.arrow.right"
            case .turn, .relay: return "server.rack"
            case .unknown: return "questionmark.circle"
            }
        }

        var description: String {
            switch self {
            case .direct: return "Direct between this iPhone and this participant, without TURN"
            case .turn: return "Through TURN for this participant"
            case .relay: return "Through the legacy audio relay, not TURN"
            case .unknown: return "The current audio path is not yet known"
            }
        }
    }

    struct Snapshot: Equatable {
        var webRTC = false
        var peers: Set<String> = []
        var connected: Set<String> = []
        var readings: [String: CallQualityReading] = [:]
        var stale: Set<String> = []
    }

    @Published private(set) var snapshot = Snapshot()
    private var expiry: Task<Void, Never>?

    deinit { expiry?.cancel() }

    func start(peers: Set<String>) {
        publish(Snapshot(webRTC: true, peers: peers))
    }

    func setPeers(_ peers: Set<String>) {
        var next = snapshot
        next.peers = peers
        next.connected.formIntersection(peers)
        next.readings = next.readings.filter { peers.contains($0.key) }
        next.stale.formIntersection(peers)
        publish(next)
    }

    func setConnected(_ peers: Set<String>) {
        var next = snapshot
        next.connected = peers.intersection(next.peers)
        next.readings = next.readings.filter { next.connected.contains($0.key) }
        next.stale.formIntersection(next.connected)
        publish(next)
    }

    func receive(_ links: [WebRTCQualityLink], at now: Date = Date()) {
        var next = snapshot
        for link in links where next.connected.contains(link.to) {
            next.readings[link.to] = CallQualityReading(link: link, received: now)
            next.stale.remove(link.to)
        }
        publish(next)
    }

    func reset() { publish(Snapshot()) }

    func indicator(peer: String? = nil, legacyConnected: Bool) -> CallQualityIndicator {
        guard snapshot.webRTC else {
            return CallQualityIndicator(transport: legacyConnected ? "TCP" : "?",
                                        quality: legacyConnected ? .unavailable : .connecting)
        }
        if let peer {
            guard snapshot.connected.contains(peer) else {
                return CallQualityIndicator(transport: "?", quality: .connecting)
            }
            if snapshot.stale.contains(peer) {
                return CallQualityIndicator(transport: "?", quality: .stale)
            }
            return snapshot.readings[peer]?.indicator(at: Date())
                ?? CallQualityIndicator(transport: "?", quality: .measuring)
        }
        return CallQualityIndicator.summary(snapshot.peers.sorted().map {
            indicator(peer: $0, legacyConnected: legacyConnected)
        })
    }

    func path(peer: String, legacyConnected: Bool) -> MediaPath {
        guard snapshot.webRTC else { return legacyConnected ? .relay : .unknown }
        guard snapshot.connected.contains(peer), !snapshot.stale.contains(peer),
              let reading = snapshot.readings[peer],
              reading.indicator(at: Date()).quality != .stale else { return .unknown }
        // Use the selected pair at BOTH ends, not UDP/TCP or merely available candidates.
        switch reading.link.relayed {
        case false?: return .direct
        case true?: return .turn
        case nil: return .unknown
        }
    }

    func expire(at now: Date) {
        var next = snapshot
        for (peer, reading) in next.readings
            where now.timeIntervalSince(reading.received) > CallQualityReading.maximumAge {
            next.stale.insert(peer)
        }
        publish(next)
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        expiry?.cancel()
        expiry = nil
        // One wakeup at the next stale deadline, not a repeating UI timer.
        let deadlines = next.readings.filter { !next.stale.contains($0.key) }.map {
            $0.value.received.addingTimeInterval(CallQualityReading.maximumAge + 0.01)
        }
        guard let deadline = deadlines.min() else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.expire(at: Date())
        }
    }
}
