import Foundation

/// Bounded cosmetic cache for one relay. Reload verifies signatures, including removal tombstones.
final class MemberProfileCache {
    private struct Saved: Codable {
        let scope: String
        let profiles: [[String: String]]
        var names: [String: String]?
    }
    private static let key = "memberProfiles.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(scope: String) -> [String: DeviceProfile] {
        guard let saved = read(scope: scope) else { return [:] }
        var result: [String: DeviceProfile] = [:]
        for message in saved.profiles {
            guard let profile = try? DeviceProfile(message) else { continue }
            if let previous = result[profile.identity], previous.revision >= profile.revision { continue }
            result[profile.identity] = profile
        }
        return result
    }

    func loadNames(scope: String) -> [String: String] {
        guard let names = read(scope: scope)?.names, names.count <= 128 else { return [:] }
        return names.filter {
            (try? VoiceProtocol.decode($0.key, size: 32)) != nil && LobbyProtocol.nameValid($0.value)
        }
    }

    private func read(scope: String) -> Saved? {
        guard let data = defaults.data(forKey: Self.key), data.count <= 1_100_000,
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.scope == scope, saved.profiles.count <= 128 else { return nil }
        return saved
    }

    func save(_ profiles: [String: DeviceProfile], scope: String, names: [String: String] = [:]) {
        let savedNames = names.filter { profiles[$0.key] != nil && LobbyProtocol.nameValid($0.value) }
        guard !scope.isEmpty, profiles.count <= 128,
              let data = try? JSONEncoder().encode(Saved(
                scope: scope, profiles: profiles.values.map(\.message), names: savedNames)),
              data.count <= 1_100_000 else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
