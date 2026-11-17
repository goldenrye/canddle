import Combine
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

    @MainActor static func wait(seconds: Double = 6, line: UInt = #line,
                                _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                print("Timed out at GroupChecks.swift:\(line)")
                throw VoiceError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func pcm(_ sample: UInt16) -> Data {
        Data((0..<320).flatMap { _ in [UInt8(truncatingIfNeeded: sample), UInt8(sample >> 8)] })
    }

    @MainActor static func audio(_ clients: [GroupStore]) async throws {
        // A caller's roster acknowledgment can precede delivery to the other
        // sockets, especially over TLS. Sending an old epoch is correctly dropped.
        let expected = Set(clients.map(\.ownIdentity))
        try await wait {
            clients.allSatisfy { $0.inCall && Set($0.members.map(\.id)) == expected }
        }
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
            try jitterChecks()
            try cryptoChecks()
            let root = try input.root.flatMap { Data(base64Encoded: $0) }.map { try RelaySettings.certificate($0) }
            let settings = try RelaySettings(address: input.address, token: input.token,
                root: root, testLoopback: true)
            var saved = (0..<7).map { _ in
                LobbyIdentity(secret: Curve25519.Signing.PrivateKey().rawRepresentation, trusted: [:])
            }
            if input.mode == "rename-directory" {
                let ids = try saved.map {
                    VoiceProtocol.base64(try Curve25519.Signing.PrivateKey(rawRepresentation: $0.secret)
                        .publicKey.rawRepresentation)
                }
                saved[0].trusted[settings.url.absoluteString + "|" + ids[1]] = "Original verified name"
                saved[0].trusted[settings.url.absoluteString + "|" + ids[2]] = "Saved offline device"
                saved[0].trusted["wss://other.example/relay|" + ids[3]] = "Other relay device"
            }
            if input.mode.hasPrefix("auto-") || (input.mode.hasPrefix("direct-") && input.mode != "direct-unverified") {
                let ids = try saved.map {
                    VoiceProtocol.base64(try Curve25519.Signing.PrivateKey(rawRepresentation: $0.secret)
                        .publicKey.rawRepresentation)
                }
                for index in 1..<7 {
                    let scope = input.mode == "auto-other-relay" ? "wss://other.example/relay" : settings.url.absoluteString
                    if input.mode != "auto-unverified" || index != 1 {
                        saved[0].trusted[scope + "|" + ids[index]] = "Renamed Phone"
                    }
                    if !["auto-unconfirmed", "auto-ignore", "auto-reject"].contains(input.mode) {
                        saved[index].trusted[settings.url.absoluteString + "|" + ids[0]] = "Caller"
                    }
                }
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
            precondition(!clients[1].rename(""))
            precondition(!clients[1].rename("   "))
            precondition(!clients[1].rename(String(repeating: "x", count: 41)))
            precondition(!clients[1].rename("Invalid\nName"))
            clients[1].connect(settings)
            precondition(clients[1].active)
            precondition(clients[1].rename("Renamed Phone"))
            precondition(!clients[1].active)
            defer { clients.forEach { $0.disconnect() } }
            let host = clients[0]
            if input.mode == "quiet-presence" {
                var presenceUpdates = 0
                var nameUpdates = 0
                let presenceObserver = host.$presence.filter { !$0.isEmpty }.sink { _ in presenceUpdates += 1 }
                let nameObserver = host.$knownNames.filter { !$0.isEmpty }.sink { _ in nameUpdates += 1 }
                defer { presenceObserver.cancel(); nameObserver.cancel() }
                host.connect(settings)
                try await wait { host.presenceReady && host.presenceTruncated }
                precondition(presenceUpdates == 1 && nameUpdates == 1,
                             "Duplicate snapshots must not republish directory state")
                precondition(host.groupDirectory.first?.state == .online)
                print("PASS group \(input.mode)")
                return
            }
            if input.mode.hasPrefix("rtc-") {
                try await webRTCChecks(clients, saved: saved, settings: settings, mode: input.mode)
                print("PASS group \(input.mode)")
                return
            }
            if input.mode.hasPrefix("profiles") {
                let guest = clients[1]
                let photo = Data([0xff, 0xd8, 0xff, 0xd9])
                host.updateProfile(photo: photo, revision: 1)
                host.connect(settings)
                guest.connect(settings)
                try await wait { host.online && guest.online && host.presenceReady && guest.presenceReady }
                if input.mode == "profiles-old" {
                    precondition(!host.profilesSupported && !guest.profilesSupported)
                    precondition(guest.profiles.isEmpty)
                } else {
                    try await wait { guest.profiles[host.ownIdentity]?.photo == photo }
                    precondition(host.trusted.isEmpty && guest.trusted.isEmpty)
                    let custom = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
                    host.updateProfile(photo: custom, revision: 2)
                    try await wait(seconds: 8) { guest.profiles[host.ownIdentity]?.photo == custom }
                    host.updateProfile(photo: Data(), revision: 3)
                    try await wait(seconds: 8) { guest.profiles[host.ownIdentity]?.photo.isEmpty == true }
                    precondition(host.online && guest.online && host.trusted.isEmpty && guest.trusted.isEmpty)
                }
                print("PASS group \(input.mode)")
                return
            }
            if input.mode == "rename-directory" {
                try await directoryRenameChecks(clients, settings: settings)
                print("PASS group \(input.mode)")
                return
            }
            if input.mode.hasPrefix("direct-") {
                try await directCallChecks(clients, settings: settings, mode: input.mode)
                print("PASS group \(input.mode)")
                return
            }
            if input.mode.hasPrefix("auto-") {
                try await automaticAdmissionChecks(clients, settings: settings, mode: input.mode)
                print("PASS group \(input.mode)")
                return
            }
            if input.mode == "cancel" {
                host.connect(settings)
                host.disconnect()
                await Task.yield()
                precondition(!host.active && !host.online && !host.inCall)
            }
            clients[1].connect(settings)
            if input.mode == "legacy-presence" {
                try await wait { clients[1].online }
                host.connect(settings, startCall: true)
                try await wait { clients[1].offers.count == 1 && !host.sending }
                precondition(!clients[1].presenceSupported && !clients[1].presenceReady)
                precondition(!host.directCallsSupported)
                clients[1].announce(target: host.ownIdentity)
                precondition(clients[1].ownOffer == nil)
                precondition(clients[1].groupDirectory.allSatisfy { $0.state == .unknown })
                clients[1].request(clients[1].offers[0])
                try await wait { host.candidates.count == 1 && !clients[1].sending }
                precondition(host.online && clients[1].online)
                print("PASS group \(input.mode)")
                return
            }
            try await wait { clients[1].online && clients[1].presenceReady }
            precondition(clients[1].groupDirectory.first?.state == .online)
            precondition(!clients[1].inCall && clients[1].offers.isEmpty)
            host.connect(settings, startCall: true)
            try await wait { host.ownOffer != nil && clients[1].offers.count == 1 && !host.sending }
            try await wait { clients[1].presence[host.ownIdentity]?.state == .calling }
            precondition(clients[1].notification != nil)
            precondition(!host.rename("Cannot change announced identity"))
            let offer = clients[1].offers[0]
            clients[1].request(offer)
            try await wait { host.candidates.count == 1 && !clients[1].sending }
            try await wait { host.presence[clients[1].ownIdentity]?.state == .joining }
            precondition(host.notification != nil)
            precondition(host.candidates[0].exchange.request.name == "Renamed Phone")
            precondition(!clients[1].rename("Cannot change pending identity"))
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
            try await wait {
                host.presence[clients[1].ownIdentity]?.state == .inCall
                    && clients[1].presence[host.ownIdentity]?.state == .inCall
            }
            precondition(!clients[1].rename("Cannot change active identity"))
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
            let hostID = host.ownIdentity
            host.disconnect()
            precondition(host.groupDirectory.allSatisfy { $0.state == .unknown })
            try await wait { clients.dropFirst().allSatisfy { !$0.inCall } }
            try await wait {
                clients[1].groupDirectory.contains { $0.id == hostID && $0.state == .disconnected }
            }
            print("PASS group \(input.mode)")
        } catch {
            print("FAIL group \(String(describing: error))")
            exit(1)
        }
    }

    @MainActor static func directoryRenameChecks(_ clients: [GroupStore],
                                                 settings: RelaySettings) async throws {
        let observer = clients[0], peer = clients[1]
        let peerID = peer.localIdentity
        observer.connect(settings)
        try await wait { observer.presenceReady }
        precondition(observer.trustedName(peerID) == "Original verified name")
        precondition(observer.groupDirectory.contains {
            $0.id == peerID && $0.name == "Original verified name" && $0.state == .disconnected
        })
        precondition(observer.groupDirectory.contains { $0.name == "Saved offline device" })
        precondition(!observer.groupDirectory.contains { $0.name == "Other relay device" })

        peer.connect(settings)
        try await wait { observer.presence[peerID]?.name == "Renamed Phone" }
        precondition(observer.groupDirectory.contains {
            $0.id == peerID && $0.name == "Renamed Phone" && $0.state == .online
        })
        precondition(peer.rename("Kitchen iPhone"))
        try await wait { observer.presence[peerID] == nil }
        peer.connect(settings)
        try await wait { observer.presence[peerID]?.name == "Kitchen iPhone" }
        precondition(observer.groupDirectory.contains {
            $0.id == peerID && $0.name == "Kitchen iPhone" && $0.state == .online
        })
        precondition(peer.groupDirectory.first?.name == "Kitchen iPhone")
        precondition(observer.trustedName(peerID) == "Original verified name")
        peer.disconnect()
        try await wait { observer.presence[peerID] == nil }
        precondition(observer.groupDirectory.contains {
            $0.id == peerID && $0.name == "Kitchen iPhone" && $0.state == .disconnected
        })
        observer.disconnect()
        precondition(observer.groupDirectory.contains {
            $0.id == peerID && $0.name == "Kitchen iPhone" && $0.state == .unknown
        })
        observer.connect(settings)
        try await wait { observer.presenceReady }
        precondition(observer.groupDirectory.contains { $0.id == peerID && $0.name == "Kitchen iPhone" })
        precondition(observer.trustedName(peerID) == "Original verified name")
    }

    @MainActor static func directCallChecks(_ clients: [GroupStore],
                                            settings: RelaySettings, mode: String) async throws {
        let host = clients[0], receiver = clients[1], observer = clients[2]
        receiver.connect(settings)
        observer.connect(settings)
        try await wait { receiver.online && observer.online }
        if mode == "direct-lock-decline" {
            let target = receiver.ownIdentity
            try await wait { observer.presence[target] != nil }
            receiver.disconnect()
            try await wait { observer.presenceReady && observer.presence[target] == nil }
            host.connect(settings, startCall: true, target: target)
            try await wait { host.ownOffer != nil && !host.sending }
            receiver.connect(settings)
            precondition(!receiver.online)
            receiver.disconnect(declining: host.ownOffer!)
            try await wait { !host.waiting && !receiver.active }
            precondition(host.online && !host.inCall && !receiver.inCall)
            return
        }
        host.connect(settings, startCall: true, target: receiver.ownIdentity)
        try await wait { receiver.offers.count == 1 && !host.sending }
        precondition(host.isIndividual && host.memberLimit == 2)
        precondition(observer.offers.isEmpty && !receiver.inCall && !host.inCall)
        precondition(!host.autoAcceptVerifiedDevices)
        let offer = receiver.offers[0]
        precondition(offer.target == receiver.ownIdentity)
        if mode == "direct-decline" {
            receiver.decline(offer)
            try await wait { !host.waiting && !receiver.sending }
            precondition(!host.inCall && !receiver.inCall)
            return
        }
        receiver.request(offer)
        if mode == "direct-unverified" {
            try await wait { host.candidates.count == 1 && !receiver.sending }
            precondition(!host.inCall && !receiver.confirmed)
            receiver.confirmCaller()
            try await wait { host.candidates[0].confirmed && !receiver.sending }
            precondition(!host.inCall && host.approving == nil)
            precondition(host.candidates[0].exchange.code == receiver.joining?.code)
            host.approve(host.candidates[0])
        }
        try await wait { host.inCall && receiver.inCall && !host.sending && !receiver.sending }
        precondition(host.members.count == 2 && receiver.memberLimit == 2)
        precondition(observer.offers.isEmpty && !observer.inCall)
        try await audio([host, receiver])
        if mode == "direct-disconnect" { receiver.disconnect() }
        else { receiver.cancelRequest() }
        try await wait { !host.waiting && !host.inCall && !receiver.inCall }
        precondition(host.online && observer.online)
    }

    @MainActor static func automaticAdmissionChecks(_ clients: [GroupStore],
                                                    settings: RelaySettings, mode: String) async throws {
        let host = clients[0], receiver = clients[1]
        precondition(!host.autoAcceptVerifiedDevices)
        host.autoAcceptVerifiedDevices = mode != "auto-disabled"
        host.connect(settings, startCall: true)
        receiver.connect(settings)
        try await wait { receiver.offers.count == 1 && !host.sending }
        precondition(!receiver.inCall && host.members.count == 1)
        let offer = receiver.offers[0]
        if mode == "auto-batch" {
            for client in clients.dropFirst(2) { client.connect(settings) }
            try await wait { clients.dropFirst().allSatisfy { $0.offers.count == 1 } }
            for client in clients.dropFirst() { client.request(offer) }
            try await wait {
                host.members.count == 6 && host.approving == nil && !host.sending
                    && clients.dropFirst().filter(\.inCall).count == 5 && host.candidates.count == 1
            }
            precondition(clients.dropFirst().filter { !$0.inCall }.allSatisfy(\.waiting))
            try await audio(clients.filter(\.inCall))
            return
        }
        receiver.request(offer)
        if ["auto-unconfirmed", "auto-ignore", "auto-reject"].contains(mode) {
            try await wait { host.candidates.count == 1 && !receiver.sending }
            precondition(!host.candidates[0].confirmed && !host.inCall)
            if mode == "auto-ignore" { host.ignore(host.candidates[0]) }
            if mode == "auto-reject" {
                host.reject(host.candidates[0])
                try await wait { !receiver.waiting && !host.sending }
                receiver.request(offer)
                try await wait { host.candidates.count == 1 && !receiver.sending }
            }
            receiver.confirmCaller()
        }
        if ["auto-disabled", "auto-unverified", "auto-other-relay", "auto-ignore", "auto-reject"].contains(mode) {
            try await wait { host.candidates.count == 1 && host.candidates[0].confirmed && !receiver.sending }
            // Give pending send completions a chance to exercise the admission queue.
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(!host.inCall && !receiver.inCall && host.approving == nil)
            host.approve(host.candidates[0])
        }
        try await wait { host.inCall && receiver.inCall && !host.sending && host.approving == nil }
        precondition(host.notification?.contains("joined the call") == true)
        try await audio(Array(clients.prefix(2)))
        if mode == "auto-enabled" {
            host.remove(host.members.first { $0.id == receiver.ownIdentity }!)
            try await wait { !receiver.inCall && host.members.count == 1 && !host.sending && host.approving == nil }
            receiver.request(offer)
            try await wait { host.candidates.count == 1 && host.candidates[0].confirmed && !receiver.sending }
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(!receiver.inCall && host.approving == nil)
            host.approve(host.candidates[0])
            try await wait { receiver.inCall && !host.sending && host.approving == nil }
            host.autoAcceptVerifiedDevices = false
            clients[2].connect(settings)
            try await wait { clients[2].offers.count == 1 }
            clients[2].request(offer)
            try await wait { host.candidates.count == 1 && host.candidates[0].confirmed && !clients[2].sending }
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(!clients[2].inCall && host.members.count == 2)
        }
    }

    static func cryptoChecks() throws {
        let host = Curve25519.Signing.PrivateKey(), peer = Curve25519.Signing.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey(), peerKey = Curve25519.KeyAgreement.PrivateKey()
        let offer = try LobbyOffer.create(identity: host, name: "Caller", ephemeral: hostKey)
        let request = try LobbyRequest.create(offer: offer, identity: peer, name: "Peer", ephemeral: peerKey)
        let direct = try LobbyOffer.create(identity: host, name: "Caller", ephemeral: hostKey,
                                           target: request.identity)
        let directRequest = try LobbyRequest.create(offer: direct, identity: peer, name: "Peer", ephemeral: peerKey)
        let pair = [GroupMember(message: direct.message), GroupMember(message: directRequest.message)]
        _ = try GroupRoster.create(offer: direct, revision: 1, members: pair, signing: host)
        try rejects {
            _ = try GroupRoster.create(offer: direct, revision: 1, members: [pair[0]], signing: host)
        }
        try rejects {
            _ = try GroupRoster.create(offer: direct, revision: 1,
                members: pair + [GroupMember(message: request.message)], signing: host)
        }
        let snapshot = ["type": "presence", "members": "[[\"\(offer.identity)\",\"Caller\",\"online\"]]",
                        "truncated": "no"]
        let parsedPresence = try GroupPresenceSnapshot(snapshot)
        precondition(parsedPresence.members.count == 1)
        for entries in [
            "[[\"bad-key\",\"Name\",\"online\"]]",
            "[[\"\(offer.identity)\",\"Name\",\"muted\"]]",
            "[[\"\(offer.identity)\",\"Name\",\"unknown\"]]",
            "[[\"\(offer.identity)\",\"Name\"]]",
            "[[\"\(offer.identity)\",\"\",\"online\"]]",
            "[[\"\(offer.identity)\",\"A\",\"online\"],[\"\(offer.identity)\",\"B\",\"online\"]]"
        ] {
            try rejects { _ = try GroupPresenceSnapshot(snapshot.merging(["members": entries]) { _, b in b }) }
        }
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
        for _ in 0..<10 { try mixer.push(pcm(20000), from: "one") }
        for _ in 0..<3 { try mixer.push(pcm(20000), from: "two") }
        precondition(mixer.droppedFrames == 2)
        for _ in 0..<3 { precondition(mixer.mix() == pcm(32767)) }
        for _ in 0..<5 { precondition(mixer.mix() == pcm(20000)) }
        precondition(mixer.mix() == VoiceProtocol.silence)
    }

    @MainActor static func webRTCChecks(_ clients: [GroupStore], saved: [LobbyIdentity],
                                        settings: RelaySettings, mode: String) async throws {
        let host = clients[0], receiver = clients[1], legacy = clients[6]
        let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtcp-mux\r\n"
            + "a=rtpmap:111 opus/48000/2\r\na=fingerprint:sha-256 "
            + Array(repeating: "AB", count: 32).joined(separator: ":") + "\r\na=mid:0\r\n"
        for client in clients.prefix(6) { client.webRTCAvailable = true }
        host.preferWebRTC = true
        receiver.connect(settings)
        legacy.connect(settings)
        host.connect(settings, startCall: mode == "rtc-legacy-cold-start")
        try await wait { host.online && receiver.presenceReady && legacy.presenceReady }
        if mode.hasPrefix("rtc-legacy-") {
            let target = mode == "rtc-legacy-direct" ? receiver.ownIdentity : nil
            if mode != "rtc-legacy-cold-start" { host.announce(target: target) }
            precondition(host.ownOffer == nil && !host.webRTCSupported)
            precondition(host.pendingLegacyCall != nil && !host.waiting)
            precondition(receiver.offers.isEmpty && legacy.offers.isEmpty)
            host.dismissLegacyCallRequest()
            precondition(host.pendingLegacyCall == nil && host.ownOffer == nil)
            host.announce(target: target)
            let stale = host.pendingLegacyCall!
            host.disconnect()
            precondition(host.pendingLegacyCall == nil)
            host.connect(settings)
            try await wait { host.online }
            host.confirmLegacyCall(stale)
            precondition(host.ownOffer == nil)
            host.announce(target: target)
            let request = host.pendingLegacyCall!
            // SwiftUI can dismiss the presentation before running its button action.
            host.dismissLegacyCallRequest()
            host.confirmLegacyCall(request)
            try await wait { receiver.offers.count == 1 && !host.sending }
            precondition(host.pendingLegacyCall == nil && host.preferWebRTC)
            precondition(!receiver.offers[0].usesWebRTC)
            precondition(receiver.offers[0].target == target)
            if target == nil { try await wait { legacy.offers.count == 1 } }
            else { precondition(legacy.offers.isEmpty) }
            receiver.request(receiver.offers[0])
            try await wait { host.candidates.count == 1 && !receiver.sending }
            receiver.confirmCaller()
            try await wait { host.candidates[0].confirmed && !host.sending }
            host.approve(host.candidates[0])
            try await wait { host.inCall && receiver.inCall && !host.sending }
            try await audio([host, receiver])
            precondition(!host.usesWebRTC && host.webRTCSession == nil)
            return
        }
        try await wait { host.webRTCSupported && receiver.webRTCSupported }
        host.announce(target: mode.contains("direct") ? receiver.ownIdentity : nil)
        try await wait { receiver.offers.count == 1 && !host.sending }
        let offer = receiver.offers[0]
        precondition(offer.usesWebRTC && legacy.offers.isEmpty && host.pendingLegacyCall == nil)
        let push = try IncomingCallPush([
            "v": 1, "scope": settings.url.absoluteString, "recipient": receiver.ownIdentity,
            "expires": Date().timeIntervalSince1970 + 30, "offer": offer.message
        ], scope: settings.url.absoluteString, recipient: receiver.ownIdentity)
        precondition(push.offer.message == offer.message)
        var stripped = offer.message
        stripped.removeValue(forKey: "media")
        try rejects { _ = try LobbyOffer(stripped) }
        var changes = 0
        host.onWebRTCSessionChanged = { if $0 != nil { changes += 1 } }
        let count = mode.contains("direct") ? 2 : 6
        for index in 1..<count {
            let client = clients[index]
            if index > 1 { client.connect(settings) }
            try await wait { client.offers.count == 1 && !client.sending }
            client.request(client.offers[0])
            try await wait { host.candidates.count == 1 && !client.sending }
            precondition(!client.inCall && client.webRTCSession == nil)
            client.confirmCaller()
            try await wait { host.candidates[0].confirmed && !host.sending }
            host.approve(host.candidates[0])
            try await wait { client.inCall && host.members.count == index + 1 && !host.sending }
        }
        precondition(changes == count - 1)
        try await wait { clients.prefix(count).allSatisfy { $0.members.count == count } }
        let session = host.webRTCSession!
        precondition(session.trickle == (mode != "rtc-no-trickle"))
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: saved[0].secret)
        let proof = try WebRTCSignal.create(sdp: sdp,
            kind: host.ownIdentity < receiver.ownIdentity ? "offer" : "answer",
            to: receiver.ownIdentity, session: session, signing: signing)
        for field in ["identity", "to", "epoch", "revision", "call", "kind", "sdp", "signature"] {
            var tampered = proof.message
            tampered[field] = "invalid"
            try rejects { _ = try WebRTCSignal(tampered, session: receiver.webRTCSession!) }
        }
        for from in clients.prefix(count) {
            for to in clients.prefix(count) where from !== to {
                let supportsTrickle = session.trickle && !(mode == "rtc-mixed" && from === receiver)
                try await from.sendWebRTC(sdp: sdp + (supportsTrickle ? WebRTCSignal.trickleAttribute + "\r\n" : ""),
                    kind: from.ownIdentity < to.ownIdentity ? "offer" : "answer",
                    to: to.ownIdentity, epoch: session.roster.message["epoch"]!)
            }
        }
        try await wait { clients.prefix(count).allSatisfy { $0.webRTCSignals.count == count - 1 } }
        for from in clients.prefix(count) {
            for to in clients.prefix(count) where from !== to {
                let enabled = session.trickle && !(mode == "rtc-mixed" && (from === receiver || to === receiver))
                if enabled {
                    try await from.sendWebRTCCandidate(
                        candidate: "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host",
                        mid: "0", to: to.ownIdentity, epoch: session.roster.message["epoch"]!)
                    try await from.sendWebRTCCandidate(candidate: "", mid: "0", to: to.ownIdentity,
                                                      epoch: session.roster.message["epoch"]!)
                } else {
                    var rejected = false
                    do {
                        try await from.sendWebRTCCandidate(candidate: "", mid: "0", to: to.ownIdentity,
                                                          epoch: session.roster.message["epoch"]!)
                    } catch { rejected = true }
                    precondition(rejected)
                }
            }
        }
        try await wait {
            clients.prefix(count).allSatisfy { client in
                let peers = session.trickle && !(mode == "rtc-mixed" && client === receiver)
                    ? count - (mode == "rtc-mixed" ? 2 : 1) : 0
                return client.webRTCCandidates.count == peers * 2
            }
        }
        for client in clients.prefix(count) {
            precondition(client.usesWebRTC && client.mixedFrame() == VoiceProtocol.silence)
        }
        precondition(legacy.offers.isEmpty)
        if mode.hasPrefix("rtc-handoff") {
            var ended = 0
            var suspended = 0
            for client in clients.prefix(count) {
                precondition(client.webRTCSession!.recovery)
                client.onAudioEnded = { _ in ended += 1 }
                client.onMediaSuspended = { suspended += 1 }
            }
            if mode.hasSuffix("timeout") || mode.hasSuffix("untrusted") {
                let started = ContinuousClock.now
                host.networkChanged()
                precondition(host.reconnecting && host.inCall)
                precondition(host.webRTCSession == nil)
                do { try await wait(seconds: 35) { !host.active } }
                catch {
                    print("Recovery deadline: active=\(host.active), inCall=\(host.inCall), "
                          + "recovering=\(host.recoveringMedia), status=\(host.status)")
                    throw error
                }
                precondition(!host.inCall && !host.reconnecting && ended >= 1)
                if mode.hasSuffix("timeout") {
                    precondition(started.duration(to: .now) >= .seconds(29))
                    precondition(host.status.contains("30 seconds"))
                } else {
                    precondition(host.status.contains("securely"))
                }
                return
            }
            if mode.hasSuffix("hangup") {
                if !mode.contains("online") {
                    receiver.networkChanged()
                    precondition(receiver.reconnecting && receiver.inCall)
                    precondition(receiver.webRTCSession == nil)
                }
                receiver.disconnect()
                try await wait { !host.inCall }
                try await Task.sleep(nanoseconds: 200_000_000)
                precondition(!receiver.active && !receiver.reconnecting && ended == 2)
                return
            }
            for stage in 0..<4 {
                let previous = host.webRTCSession!.roster
                if stage == 0 && mode != "rtc-handoff-abort" { host.networkChanged() }
                if stage == 1 { receiver.networkChanged() }
                if stage == 2 {
                    host.networkChanged()
                    receiver.networkChanged()
                }
                if stage == 3 { precondition(receiver.recoverMedia()) }
                try await wait {
                    clients.prefix(count).allSatisfy {
                        $0.online && !$0.reconnecting && $0.inCall
                            && ($0.webRTCSession?.roster.revision ?? 0) > previous.revision
                    }
                }
                let fresh = host.webRTCSession!
                precondition(fresh.roster.message["epoch"] != previous.message["epoch"])
                precondition(fresh.roster.members.map(\.message) == previous.members.map(\.message))
                precondition(ended == 0)
                // The old SDP/candidate budget must not leak into the fresh epoch.
                for from in clients.prefix(count) {
                    for to in clients.prefix(count) where from !== to {
                        try await from.sendWebRTC(sdp: sdp + WebRTCSignal.trickleAttribute + "\r\n",
                            kind: from.ownIdentity < to.ownIdentity ? "offer" : "answer",
                            to: to.ownIdentity, epoch: fresh.roster.message["epoch"]!)
                    }
                }
                try await wait { clients.prefix(count).allSatisfy { $0.webRTCSignals.count == count - 1 } }
                try await receiver.sendWebRTCCandidate(candidate: "", mid: "0",
                    to: host.ownIdentity, epoch: fresh.roster.message["epoch"]!)
                try await wait { host.webRTCCandidates.count == 1 }
            }
            precondition(suspended >= 5 && ended == 0)
        }
        if mode == "rtc-no-recovery" {
            precondition(!session.recovery)
            host.networkChanged()
            precondition(!host.reconnecting && host.inCall && !host.recoverMedia())
        }
        if mode == "rtc-group" {
            host.remove(host.members.first { $0.id == receiver.ownIdentity }!)
            try await wait { !receiver.inCall && host.members.count == count - 1 }
            precondition(receiver.webRTCSession == nil && receiver.webRTCSignals.isEmpty)
            precondition(host.webRTCSignals.isEmpty)
            precondition(host.webRTCCandidates.isEmpty && receiver.webRTCCandidates.isEmpty)
            try rejects { _ = try WebRTCSignal(proof.message, session: host.webRTCSession!) }
        }
        host.cancelRequest()
        try await wait { clients.prefix(count).allSatisfy { !$0.inCall } }
    }

    static func jitterChecks() throws {
        var mixer = GroupMixer()
        mixer.reset(["speaker"])
        // Delivery comes in bursts, but the speaker must receive a continuous
        // sequence after priming rather than alternating speech and silence.
        for tick in 0..<92 {
            if tick == 0 { try mixer.push(pcm(1), from: "speaker") }
            if tick == 2 {
                try mixer.push(pcm(2), from: "speaker")
                try mixer.push(pcm(3), from: "speaker")
            }
            if tick >= 5 && (tick - 5) % 3 == 0 {
                for value in (tick - 1)...(tick + 1) {
                    try mixer.push(pcm(UInt16(value)), from: "speaker")
                }
            }
            let frame = mixer.mix()
            precondition(frame == (tick < 2 ? VoiceProtocol.silence : pcm(UInt16(tick - 1))))
        }
        precondition(mixer.underruns == 0 && mixer.droppedFrames == 0)
        // Repeated empty ticks must neither replay old speech nor repeatedly
        // increase the target. One underrun raises the next reserve to 4 frames.
        for _ in 0..<50 { precondition(mixer.mix() == VoiceProtocol.silence) }
        precondition(mixer.underruns == 1)
        for value in 1...3 {
            try mixer.push(pcm(UInt16(value)), from: "speaker")
            precondition(mixer.mix() == VoiceProtocol.silence)
        }
        try mixer.push(pcm(4), from: "speaker")
        precondition(mixer.mix() == pcm(1))
        for value in 2...4 { precondition(mixer.mix() == pcm(UInt16(value))) }
        // Further gaps raise the reserve, but never beyond six frames.
        for target in [5, 6, 6] {
            precondition(mixer.mix() == VoiceProtocol.silence)
            for value in 1...target {
                try mixer.push(pcm(UInt16(value)), from: "speaker")
                precondition(mixer.mix() == (value == target ? pcm(1) : VoiceProtocol.silence))
            }
            for value in 2...target { precondition(mixer.mix() == pcm(UInt16(value))) }
        }
        mixer.reset(["replacement"])
        precondition(mixer.underruns == 0 && mixer.droppedFrames == 0)
        for _ in 0..<10 { precondition(mixer.mix() == VoiceProtocol.silence) }
        try rejects { try mixer.push(pcm(1), from: "speaker") }
        try rejects { try mixer.push(Data(), from: "replacement") }
        // Overflow retains recent audio, with no unbounded catch-up backlog.
        for value in 1...20 { try mixer.push(pcm(UInt16(value)), from: "replacement") }
        precondition(mixer.droppedFrames == 12)
        for value in 13...20 { precondition(mixer.mix() == pcm(UInt16(value))) }
    }

    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw VoiceError.peer
    }
}
