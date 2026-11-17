import ContactsUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProfilePhotoSettings: View {
    @ObservedObject var photos: ProfilePhotoStore
    let disabled: Bool

    var body: some View {
        Section {
            HStack(spacing: 16) {
                ProfilePhotoCircle(data: photos.photo, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your photo").font(.headline)
                    Text(photos.custom != nil ? "Custom photo"
                         : (photos.contact != nil ? "Contact photo" : "No photo selected"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if photos.loading { ProgressView().accessibilityLabel("Preparing photo") }
            }.padding(.vertical, 4)
            Button("Choose your contact photo") { photos.picker = .contact }
                .accessibilityIdentifier("chooseContactPhoto")
            Button("Choose a custom photo") { photos.picker = .photos }
                .accessibilityIdentifier("chooseCustomPhoto")
            if photos.custom != nil && photos.contact != nil {
                Button("Use contact photo instead") { photos.useContactPhoto() }
                    .accessibilityIdentifier("restoreContactPhoto")
            }
            if !photos.photo.isEmpty {
                Button("Remove photo", role: .destructive) { photos.removePhoto() }
                    .accessibilityIdentifier("removeProfilePhoto")
            }
            if let error = photos.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Profile photo")
        } footer: {
            Text("iOS cannot share your Messages photo automatically. Select your own contact card once "
                 + "to use its photo as the default. A custom photo overrides it. "
                 + "A small square copy is shared with members on your relay when online. "
                 + "The relay can see it; your address book and photo metadata are not uploaded. "
                 + "Sharing requires updated apps and relay.")
        }
        .disabled(disabled || photos.loading)
        .sheet(item: $photos.picker) { source in
            ProfilePhotoPicker(source: source, selected: { data in
                photos.select(data, fromContact: source == .contact)
            }, loading: photos.startLoading, failed: photos.reportError, finished: { photos.picker = nil })
        }
    }
}

struct ProfilePhotoCircle: View {
    let data: Data
    var size: CGFloat = 44
    var tint: Color = .teal
    var symbol = "person.fill"

    var body: some View {
        Group {
            if let image = ProfileImage.sharedImage(data) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct ProfilePhotoPicker: UIViewControllerRepresentable {
    let source: ProfilePhotoStore.Source
    let selected: (Data) -> Void
    let loading: () -> Void
    let failed: (String) -> Void
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        if source == .contact {
            let picker = CNContactPickerViewController()
            picker.delegate = context.coordinator
            picker.predicateForSelectionOfContact = NSPredicate(value: true)
            return picker
        }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, CNContactPickerDelegate, PHPickerViewControllerDelegate {
        let parent: ProfilePhotoPicker
        init(_ parent: ProfilePhotoPicker) { self.parent = parent }

        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            Task { @MainActor in self.parent.finished() }
        }

        nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let thumbnail = contact.isKeyAvailable(CNContactThumbnailImageDataKey) ? contact.thumbnailImageData : nil
            let data = thumbnail ?? (contact.isKeyAvailable(CNContactImageDataKey) ? contact.imageData : nil)
            Task { @MainActor in
                self.parent.finished()
                if let data { self.parent.selected(data) }
                else {
                    self.parent.failed("That contact has no available photo. Choose another card or a custom photo.")
                }
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.finished()
            guard let item = results.first else { return }
            parent.loading()
            item.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [parent] url, _ in
                let result: Data?
                if let url,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size <= ProfileImage.maximumInputBytes {
                    result = try? Data(contentsOf: url)
                } else {
                    result = nil
                }
                Task { @MainActor in
                    if let result { parent.selected(result) }
                    else { parent.failed("Could not load that photo. Try a downloaded image smaller than 25 MB.") }
                }
            }
        }
    }
}
