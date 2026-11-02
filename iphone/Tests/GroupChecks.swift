import CryptoKit
import Foundation

@main
struct GroupChecks {
    struct Input: Decodable {
        let address: String
        let token: String
        let mode: String
        let root: String?
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VoiceError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func pcm(_ sample: UInt16) -> Data {
        Data((0..<320).flatMap { _ in [UInt8(truncatingIfNeeded: sample), UInt8(sample >> 8)] })
    }

    @MainActor static func audio(_ clients: [GroupStore]) async throws {
        for (index, client) in clients.enumerated() {
            try await client.transmit(pcm(UInt16(100 * (index + 1))))
        }
        let sum = 100 * clients.count * (clients.count + 1) / 2
        for (index, client) in clients.enumerated() {
            var accumulated = 0
            try await wait {
                let frame = [UInt8](client.mixedFrame())
                accumulated += Int(frame[0]) + Int(frame[1]) * 256
                return accumulated == sum - 100 * (index + 1)
            }
        }
    }

    @MainActor static func main() async {
        do {
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            try cryptoChecks()
            let root = try input.root.flatMap { Data(base64Encoded: $0) }.map { try RelaySettings.certificate($0) }
            let settings = try RelaySettings(address: input.address, token: input.token,
                root: root, testLoopback: true)
            var saved = (0..<7).map { _ in
                LobbyIdentity(secret: Curve25519.Signing.PrivateKey().rawRepresentation, trusted: [:])
            }
            let clients = (0..<7).map { index in
                GroupStore(loadIdentity: { saved[index] }, saveIdentity: {
                    if input.mode == "save-failure" || (input.mode == "caller-save-failure" && index == 0) {
                        throw VoiceError.ended
                    }
                    saved[index] = $0
                })
            }
            for (index, client) in clients.enumerated() { client.name = "Phone \(index)" }
            defer { clients.forEach { $0.disconnect() } }
            let host = clients[0]
            if input.mode == "cancel" {
                host.connect(settings)
                host.disconnect()
                await Task.yield()
                precondition(!host.active && !host.online && !host.inCall)
            }
            clients[1].connect(settings)
            try await wait { clients[1].online }
            precondition(!clients[1].inCall && clients[1].offers.isEmpty)
            host.connect(settings, startCall: true)
            try await wait { host.ownOffer != nil && clients[1].offers.count == 1 && !host.sending }
            precondition(clients[1].notification != nil)
            let offer = clients[1].offers[0]
            clients[1].request(offer)
            try await wait { host.candidates.count == 1 && !clients[1].sending }
            precondition(host.notification != nil)
            host.approve(host.candidates[0])
            precondition(!host.inCall)
            clients[1].confirmCaller()
            if input.mode == "save-failure" {
                precondition(!clients[1].confirmed && !host.inCall)
                print("PASS group \(input.mode)")
                return
            }
            try await wait { host.candidates[0].confirmed && !clients[1].sending }
            host.approve(host.candidates[0])
            if input.mode == "caller-save-failure" {
                precondition(!host.inCall && host.approving == nil && !clients[1].inCall)
                precondition(host.status.contains("Nothing sent"))
                print("PASS group \(input.mode)")
                return
            }
            try await wait { host.members.count == 2 && clients[1].inCall && !host.sending }
            try await audio(Array(clients.prefix(2)))

            if input.mode == "reject" || input.mode == "ignore" {
                clients[2].connect(settings)
                try await wait { clients[2].offers.count == 1 }
                clients[2].request(clients[2].offers[0])
                try await wait { host.candidates.count == 1 && !clients[2].sending }
                if input.mode == "reject" { host.reject(host.candidates[0]) }
                else {
                    host.ignore(host.candidates[0])
                    precondition(host.visibleCandidates.isEmpty)
                }
                try await wait { !clients[2].waiting }
                precondition(host.members.count == 2 && !clients[2].inCall)
                try await audio(Array(clients.prefix(2)))
            } else {
                let count = input.mode == "capacity" ? 6 : 4
                for index in 2..<count {
                    clients[index].connect(settings)
                    try await wait { clients[index].offers.count == 1 }
                    clients[index].request(clients[index].offers[0])
                    try await wait { host.candidates.count == 1 && !clients[index].sending }
                    clients[index].confirmCaller()
                    try await wait { host.candidates[0].confirmed && !clients[index].sending }
                    host.approve(host.candidates[0])
                    try await wait {
                        clients.prefix(index + 1).allSatisfy { $0.inCall && $0.members.count == index + 1 }
                            && !host.sending
                    }
                    try await audio(Array(clients.prefix(index + 1)))
                }
                if input.mode == "streaming" {
                    let streams = clients.prefix(4).map { client in
                        Task { @MainActor in
                            for _ in 0..<100 {
                                try await client.transmit(pcm(100))
                                try await Task.sleep(nanoseconds: 20_000_000)
                            }
                        }
                    }
                    defer { streams.forEach { $0.cancel() } }
                    clients[4].connect(settings)
                    try await wait { clients[4].offers.count == 1 }
                    clients[4].request(clients[4].offers[0])
                    try await wait { host.candidates.count == 1 && !clients[4].sending }
                    clients[4].confirmCaller()
                    try await wait { host.candidates[0].confirmed && !host.sending }
                    host.approve(host.candidates[0])
                    try await wait { clients[4].inCall && host.members.count == 5 && !host.sending }
                    try await wait { clients[4].mixedFrame() != VoiceProtocol.silence }
                    clients[4].cancelRequest()
                    try await wait { host.members.count == 4 && !host.sending }
                    for stream in streams { try await stream.value }
                    precondition(clients.prefix(4).allSatisfy { $0.inCall && $0.online })
                    for client in clients.prefix(4) {
                        for _ in 0..<6 { _ = client.mixedFrame() }
                    }
                }
                if input.mode == "capacity" {
                    clients[6].connect(settings)
                    try await wait { clients[6].offers.count == 1 }
                    clients[6].request(clients[6].offers[0])
                    try await wait { host.candidates.count == 1 && !clients[6].sending }
                    clients[6].confirmCaller()
                    try await wait { host.candidates[0].confirmed }
                    host.approve(host.candidates[0])
                    precondition(host.members.count == 6 && host.approving == nil && !clients[6].inCall)
                } else {
                    if input.mode == "disconnect" { clients[3].disconnect() }
                    else { clients[3].cancelRequest() }
                    try await wait { host.members.count == 3 && !host.sending && host.approving == nil }
                    try await audio(Array(clients.prefix(3)))
                    // Caller removal creates a new epoch; the removed phone cannot send.
                    host.remove(host.members.first { $0.id == clients[2].ownIdentity }!)
                    try await wait { !clients[2].inCall && host.members.count == 2 && !host.sending }
                    try await audio(Array(clients.prefix(2)))
                    // Returning verified peer needs exactly one Join call tap.
                    clients[2].request(offer)
                    try await wait { host.candidates.count == 1 && host.candidates[0].confirmed && !clients[2].sending }
                    precondition(clients[2].confirmed)
                    host.approve(host.candidates[0])
                    try await wait { clients[2].inCall && host.members.count == 3 && !host.sending }
                    try await audio(Array(clients.prefix(3)))
                }
            }
            host.disconnect()
            try await wait { clients.dropFirst().allSatisfy { !$0.inCall } }
            print("PASS group \(input.mode)")
        } catch {
            print("FAIL group \(String(describing: error))")
            exit(1)
        }
    }

    static func cryptoChecks() throws {
        let host = Curve25519.Signing.PrivateKey(), peer = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey(), peerKey = Curve25519.KeyAgreement.PrivateKey()
        let offer = try LobbyOffer.create(identity: host, name: "Caller", ephemeral: hostKey)
        let request = try LobbyRequest.create(offer: offer, identity: peer, name: "Peer", ephemeral: peerKey)
        let members = [GroupMember(message: offer.message), GroupMember(message: request.message)]
        let roster = try GroupRoster.create(offer: offer, revision: 1, members: members, signing: host)
        var a = try GroupCipher(roster: roster, identity: offer.identity, ephemeral: hostKey)
        var b = try GroupCipher(roster: roster, identity: request.identity, ephemeral: peerKey)
        let packet = try a.seal(pcm(300), to: request.identity)
        let forwarded = try VoiceProtocol.decode(offer.identity, size: 32) + packet.dropFirst(32)
        guard try b.open(forwarded)?.1 == pcm(300) else { throw VoiceError.packet }
        try rejects { _ = try b.open(forwarded) }
        var tampered = try a.seal(pcm(400), to: request.identity)
        tampered.replaceSubrange(0..<32, with: try VoiceProtocol.decode(offer.identity, size: 32))
        tampered[50] ^= 1
        try rejects { _ = try b.open(tampered) }
        let next = try GroupRoster.create(offer: offer, revision: 2, members: members, signing: host)
        var fresh = try GroupCipher(roster: next, identity: request.identity, ephemeral: peerKey)
        let stale = try fresh.open(forwarded)
        precondition(stale == nil)
        var falseEpoch = forwarded
        falseEpoch[39] = 2
        try rejects { _ = try fresh.open(falseEpoch) }
        var corrupt = roster.message
        corrupt["revision"] = "2"
        try rejects { _ = try GroupRoster(corrupt, offer: offer) }
        let outsiderKey = Curve25519.KeyAgreement.PrivateKey()
        try rejects { _ = try GroupCipher(roster: roster, identity: request.identity, ephemeral: outsiderKey) }
        let outsider = Curve25519.Signing.PrivateKey()
        let thirdRequest = try LobbyRequest.create(offer: offer, identity: outsider, name: "Third", ephemeral: outsiderKey)
        let three = try GroupRoster.create(offer: offer, revision: 3,
            members: members + [GroupMember(message: thirdRequest.message)], signing: host)
        var third = try GroupCipher(roster: three, identity: thirdRequest.identity, ephemeral: outsiderKey)
        var receiver = try GroupCipher(roster: three, identity: request.identity, ephemeral: peerKey)
        let forged = try third.seal(pcm(100), to: request.identity)
        let impersonated = try VoiceProtocol.decode(offer.identity, size: 32) + forged.dropFirst(32)
        try rejects { _ = try receiver.open(impersonated) }
        let original = try VoiceProtocol.decode(thirdRequest.identity, size: 32) + forged.dropFirst(32)
        guard try receiver.open(original)?.1 == pcm(100) else { throw VoiceError.packet }
        // A late participant cannot decrypt the earlier A/B conversation.
        falseEpoch[39] = 3
        try rejects { _ = try third.open(falseEpoch) }
        var mixer = GroupMixer()
        mixer.reset(["one", "two"])
        for _ in 0..<8 { try mixer.push(pcm(20000), from: "one") }
        try mixer.push(pcm(20000), from: "two")
        precondition(mixer.mix() == pcm(32767))
        for _ in 0..<4 { precondition(mixer.mix() == pcm(20000)) }
        precondition(mixer.mix() == VoiceProtocol.silence)
    }

    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw VoiceError.peer
    }
}
