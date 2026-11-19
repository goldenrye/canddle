import Foundation

@main struct CallPhaseChecks {
    static func main() {
        func check(_ state: CallPhase.State, _ phase: CallPhase) {
            precondition(CallPhase.resolve(state) == phase,
                         "Expected \(phase), got \(CallPhase.resolve(state))")
        }
        check(.init(configured: false), .setup)
        check(.init(), .offline)
        check(.init(relayConnecting: true), .relayConnecting)
        check(.init(online: true), .ready)
        check(.init(online: true, pairing: true, audioBusy: true), .pairing)
        // Being online must never mask a pending call.
        check(.init(online: true, calling: true), .calling)
        check(.init(online: true, calling: true, requests: 1), .peerVerification)
        check(.init(online: true, calling: true, requests: 2, confirmedRequests: 1), .approvalNeeded)
        check(.init(calling: true, requests: 1, confirmedRequests: 1, approving: true), .approving)
        check(.init(online: true, joining: true), .verifyCaller)
        check(.init(online: true, joining: true, confirmed: true), .waitingApproval)
        check(.init(online: true, admitted: true, calling: true), .audioConnecting)
        check(.init(online: true, audioBusy: true, admitted: true, joining: true), .audioConnecting)
        check(.init(online: true, audioBusy: true, audioConnected: true, admitted: true), .connected)
        // A new join request does not replace an established call's status.
        check(.init(audioConnected: true, admitted: true, calling: true,
                    requests: 1, confirmedRequests: 1), .connected)
        // Recovery takes precedence over stale audio and offline signaling state.
        check(.init(audioBusy: true, audioConnected: true, admitted: true, recovering: true), .recovering)
        check(.init(audioBusy: true), .audioConnecting) // Legacy/manual-room calls.
        check(.init(audioBusy: true, audioConnected: true), .connected)
        check(.init(online: true), .ready) // Hangup clears the call presentation.
        precondition(CallPhase.calling.stage == 0)
        precondition(CallPhase.verifyCaller.stage == 1)
        precondition(CallPhase.approvalNeeded.needsAction && CallPhase.verifyCaller.needsAction)
        precondition(!CallPhase.waitingApproval.needsAction && !CallPhase.peerVerification.needsAction)
        precondition(CallPhase.audioConnecting.stage == 2 && CallPhase.recovering.stage == 2)
        precondition(CallPhase.connected.stage == 3 && CallPhase.ready.stage == nil)
        print("PASS call presentation: setup, dialing, verification, approval, audio, recovery and teardown")
    }
}
