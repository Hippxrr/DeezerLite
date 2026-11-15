import PhotosUI
import SwiftUI

/// Import d'un MP3 (fichier choisi) ou modification d'un MP3 déjà envoyé sur le compte.
struct Mp3Edit: Identifiable {
    let id = UUID()
    /// MP3 déjà envoyé (modification) ; `nil` : nouvel import.
    let track: Track?
    /// Fichier à envoyer (import seulement).
    let file: Data?
    let fileName: String
    let title: String
    let artist: String
}

/// Fenêtre nom (obligatoire), artiste et pochette d'un MP3. À l'import, nom, artiste et pochette sont écrits dans le
/// fichier avant l'envoi : Deezer les reprend, ils apparaissent partout. Un MP3 déjà envoyé : Deezer ne permet pas de
/// changer sa pochette, elle est gardée sur ce téléphone.
struct Mp3EditView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let edit: Mp3Edit
    @State private var title: String
    @State private var artist: String
    /// Pochette choisie et cadrée (JPEG carré).
    @State private var cover: Data?
    @State private var preview: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var crop: CropRequest?
    @State private var sending = false

    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    init(edit: Mp3Edit) {
        self.edit = edit
        _title = State(initialValue: edit.title)
        _artist = State(initialValue: edit.artist)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Nom")) {
                    TextField(tr("Nom du titre"), text: $title)
                }
                Section(tr("Artiste")) {
                    TextField(tr("Artiste"), text: $artist)
                }
                Section {
                    HStack(spacing: 14) {
                        Group {
                            if let preview {
                                Image(uiImage: preview).resizable().scaledToFill()
                            } else {
                                CoverView(url: edit.track.flatMap { player.cover($0) }, side: 64, radius: 10)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        PhotosPicker(selection: $photo, matching: .images) { Text(tr("Choisir la pochette…")) }
                    }
                } header: {
                    Text(tr("Pochette"))
                } footer: {
                    if edit.track != nil {
                        Text(tr("Deezer ne permet pas de changer la pochette d'un MP3 déjà envoyé : elle est gardée sur ce téléphone."))
                    }
                }
            }
            .navigationTitle(edit.track == nil ? tr("Importer un MP3") : tr("Modifier le MP3"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annuler")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.track == nil ? tr("Importer") : tr("Enregistrer")) {
                        sending = true
                        Task {
                            await player.saveMp3(edit, title: title, artist: artist, cover: cover)
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let image = await Task.detached(priority: .userInitiated) { CoverCropView.load(data) }.value
                guard let image else { player.showToast(tr("Image illisible : choisis une autre photo."), seconds: 4); return }
                crop = CropRequest(image: image)
            }
        }
        .fullScreenCover(item: $crop) { c in
            CoverCropView(image: c.image) { data in
                cover = data
                preview = UIImage(data: data)
            }
        }
    }
}

/// Image de la page MP3 (Bibliothèque) : une note de musique sur un dégradé.
struct Mp3Art: View {
    var side: CGFloat
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.62, blue: 1), Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: "music.note").font(.system(size: side * 0.4, weight: .semibold)).foregroundStyle(.white)
            }
    }
}
