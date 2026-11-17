import Combine
import Foundation

@MainActor
final class ProfilePhotoStore: ObservableObject {
    enum Source: String, Identifiable {
        case contact, photos
        var id: String { rawValue }
    }
    @Published var picker: Source?
    private struct Saved: Codable {
        var contact: Data?
        var custom: Data?
        var revision: UInt64
    }

    @Published private(set) var contact: Data?
    @Published private(set) var custom: Data?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    var photo: Data { custom ?? contact ?? Data() }
    var onChange: ((Data, UInt64) -> Void)?
    private let defaults: UserDefaults
    private var generation = UUID()
    private static let key = "profilePhoto.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key) else { return }
        guard data.count <= 20000, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.revision > 0, saved.revision < UInt64.max,
              [saved.contact, saved.custom].allSatisfy({
                  $0 == nil || ProfileImage.sharedImage($0!) != nil
              }) else {
            error = "The saved profile photo could not be read. Please choose it again."
            return
        }
        contact = saved.contact
        custom = saved.custom
        revision = saved.revision
    }

    func select(_ data: Data, fromContact: Bool) {
        let id = UUID()
        generation = id
        loading = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ProfileImage.prepare(data) }
            }.value
            guard generation == id else { return }
            loading = false
            switch result {
            case .success(let photo):
                save(contact: fromContact ? photo : contact, custom: fromContact ? nil : photo)
            case .failure:
                error = "Could not use that picture. Choose a photo smaller than 25 MB."
            }
        }
    }

    func startLoading() { loading = true; error = nil }
    func reportError(_ message: String) { loading = false; error = message }
    func useContactPhoto() { save(contact: contact, custom: nil) }
    func removePhoto() { save(contact: nil, custom: nil) }

    private func save(contact: Data?, custom: Data?) {
        generation = UUID()
        loading = false
        let next = max(revision + 1, UInt64(Date().timeIntervalSince1970 * 1000))
        let record = Saved(contact: contact, custom: custom, revision: next)
        guard let encoded = try? JSONEncoder().encode(record) else {
            error = "Could not save the profile photo."
            return
        }
        defaults.set(encoded, forKey: Self.key)
        self.contact = contact
        self.custom = custom
        revision = next
        error = nil
        onChange?(photo, revision)
    }
}
