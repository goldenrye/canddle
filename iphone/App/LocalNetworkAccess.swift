import Combine
import Network

/// Asks for and tracks iOS Local Network access.
///
/// Without it, iOS silently drops packets to other devices on the same Wi-Fi,
/// so WebRTC cannot use the direct host path and falls back to TURN. iOS has no
/// API to read the setting. A Bonjour browse is the documented trigger for the
/// prompt, and it reports PolicyDenied while access is off (Apple TN3179).
/// The browse only listens for the app's own service type; nothing is advertised.
@MainActor
final class LocalNetworkAccess: ObservableObject {
    enum State: Equatable { case unknown, granted, denied }

    /// kDNSServiceErr_PolicyDenied from dns_sd.h.
    private static let policyDenied: DNSServiceErrorType = -65570

    @Published private(set) var state = State.unknown
    private var browser: NWBrowser?

    /// Value for the `lan` quality field: 1 on, 0 off, nil unknown.
    var reportValue: Int? {
        switch state {
        case .granted: return 1
        case .denied: return 0
        case .unknown: return nil
        }
    }

    /// Shows the system prompt the first time; afterwards it keeps `state`
    /// current, including when the person changes it in Settings.
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_canddle._udp", domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.receive(update) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func receive(_ update: NWBrowser.State) {
        switch update {
        case .ready:
            state = .granted
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == Self.policyDenied { state = .denied }
        default:
            break
        }
    }
}
