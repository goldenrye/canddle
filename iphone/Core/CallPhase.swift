import Foundation

/// Presentation only. Admission and microphone authorization remain in the call stores.
enum CallPhase: String {
    case setup, offline, relayConnecting, ready, pairing, incoming
    case calling, peerVerification, approvalNeeded, approving, verifyCaller, waitingApproval
    case audioConnecting, connected, recovering

    struct State {
        var configured = true
        var online = false
        var relayConnecting = false
        var pairing = false
        var audioBusy = false
        var audioConnected = false
        var admitted = false
        var recovering = false
        var calling = false
        var incoming = false
        var joining = false
        var confirmed = false
        var requests = 0
        var confirmedRequests = 0
        var approving = false
    }

    static func resolve(_ state: State) -> Self {
        if state.pairing { return .pairing }
        if state.recovering { return .recovering }
        // Roster admission alone is not a connected audio path.
        if state.admitted || state.audioBusy {
            return state.audioConnected ? .connected : .audioConnecting
        }
        if state.calling {
            if state.approving { return .approving }
            if state.confirmedRequests > 0 { return .approvalNeeded }
            if state.requests > 0 { return .peerVerification }
            return .calling
        }
        if state.joining { return state.confirmed ? .waitingApproval : .verifyCaller }
        if state.incoming { return .incoming }
        if !state.configured { return .setup }
        if state.online { return .ready }
        return state.relayConnecting ? .relayConnecting : .offline
    }

    var title: String {
        switch self {
        case .setup: return "Welcome to Canddle"
        case .offline: return "Not connected"
        case .relayConnecting: return "Connecting to your group"
        case .ready: return "Ready to call"
        case .pairing: return "Pairing this iPhone"
        case .incoming: return "Incoming call"
        case .calling: return "Waiting for an answer"
        case .peerVerification: return "Answer received"
        case .approvalNeeded: return "Your approval is needed"
        case .approving: return "Accepting participant"
        case .verifyCaller: return "Verify this caller"
        case .waitingApproval: return "Waiting for acceptance"
        case .audioConnecting: return "Connecting audio"
        case .connected: return "Call connected"
        case .recovering: return "Reconnecting your call"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "qrcode.viewfinder"
        case .offline: return "wifi.slash"
        case .relayConnecting: return "network"
        case .ready: return "phone.fill"
        case .pairing: return "qrcode"
        case .incoming: return "phone.arrow.down.left"
        case .calling: return "phone.arrow.up.right"
        case .peerVerification, .waitingApproval: return "person.badge.clock"
        case .approvalNeeded, .verifyCaller: return "person.crop.circle.badge.checkmark"
        case .approving, .audioConnecting: return "waveform"
        case .connected: return "lock.shield.fill"
        case .recovering: return "arrow.triangle.2.circlepath"
        }
    }

    var needsAction: Bool { self == .incoming || self == .approvalNeeded || self == .verifyCaller }

    /// The highlighted stage. Connected completes all three; no ticking UI timer.
    var stage: Int? {
        switch self {
        case .calling, .incoming: return 0
        case .peerVerification, .approvalNeeded, .approving, .verifyCaller, .waitingApproval: return 1
        case .audioConnecting, .recovering: return 2
        case .connected: return 3
        default: return nil
        }
    }

    var isCall: Bool { stage != nil }
}
