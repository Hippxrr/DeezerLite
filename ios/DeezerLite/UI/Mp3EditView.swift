import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Choix d'un MP3 en mode copie : le fichier est copié pour l'app au lieu d'être ouvert sur place. Ouvert sur place
/// (`fileImporter`), « Ouvrir » ne répondait pas dans une app installée hors App Store (LiveContainer…).
struct Mp3FilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mp3], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

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
    let album: String
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
    @State private var album: String
    /// Pochette choisie et cadrée (JPEG carré).
    @State private var cover: Data?
    @State private var preview: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var crop: CropRequest?
    @State private var sending = false
    /// « Pochette d'origine » choisie : la pochette mise sur ce téléphone est retirée à l'enregistrement.
    @State private var resetCover = false
    /// Import : partie gardée (secondes), coupée entre deux trames à l'envoi ; écoute pour placer le début et la fin.
    @State private var length: Double = 0
    @State private var from: Double = 0
    @State private var to: Double = 0
    @State private var listener: AVAudioPlayer?
    @State private var listening: Task<Void, Never>?

    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    init(edit: Mp3Edit) {
        self.edit = edit
        _title = State(initialValue: edit.title)
        _artist = State(initialValue: edit.artist)
        _album = State(initialValue: edit.album)
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
                Section(tr("Album")) {
                    TextField(tr("Facultatif"), text: $album)
                }
                Section {
                    HStack(spacing: 14) {
                        Group {
                            if let preview {
                                Image(uiImage: preview).resizable().scaledToFill()
                            } else {
                                CoverView(url: resetCover ? edit.track?.coverUrl : edit.track.flatMap { player.cover($0) }, side: 64, radius: 10)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        PhotosPicker(selection: $photo, matching: .images) {
                            Text(edit.track == nil ? tr("Choisir la pochette…") : tr("Pochette sur ce téléphone…"))
                        }
                    }
                    if let track = edit.track, cover != nil || (!resetCover && player.mp3Cover(track) != nil) {
                        Button(tr("Pochette d'origine")) {
                            cover = nil
                            preview = nil
                            resetCover = true
                        }
                    }
                } header: {
                    Text(tr("Pochette"))
                } footer: {
                    if edit.track != nil {
                        Text(tr("Pochette visible seulement sur ce téléphone : Deezer ne permet pas de changer celle d'un MP3 déjà envoyé (l'app Deezer, le site et l'ordinateur gardent l'ancienne). Pour la changer partout, réimporte le MP3 avec la nouvelle pochette."))
                    }
                }
                if edit.file != nil, length >= 2 {
                    Section {
                        LabeledContent(tr("Début"), value: Self.time(from))
                        Slider(value: $from, in: 0...length, onEditingChanged: { editing in if !editing { listen(at: from) } })
                            .accessibilityLabel(tr("Début"))
                        LabeledContent(tr("Fin"), value: Self.time(to))
                        Slider(value: $to, in: 0...length, onEditingChanged: { editing in if !editing { listen(at: max(from, to - 3)) } })
                            .accessibilityLabel(tr("Fin"))
                        Button(listening == nil ? tr("Écouter") : tr("Pause")) {
                            if listening == nil { listen(at: from) } else { stopListening() }
                        }
                    } header: {
                        Text(tr("Couper"))
                    } footer: {
                        Text(tr("%@ gardées. Relâche un curseur pour écouter à cet endroit.", Self.time(to - from)))
                    }
                    // Au moins 1 s gardée.
                    .onChange(of: from) { _, v in if v > to - 1 { from = max(0, to - 1) } }
                    .onChange(of: to) { _, v in if v < from + 1 { to = min(length, from + 1) } }
                }
            }
            .navigationTitle(edit.track == nil ? tr("Importer un MP3") : tr("Modifier le MP3"))
            .task { prepareCut() }
            .onDisappear { stopListening() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annuler")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.track == nil ? tr("Importer") : tr("Enregistrer")) {
                        sending = true
                        Task {
                            stopListening()
                            await player.saveMp3(edit, title: title, artist: artist, album: album, cover: cover, resetCover: resetCover, cut: cutRange)
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
                resetCover = false
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

extension Mp3EditView {
    /// Partie gardée en ms (`end` 0 : jusqu'à la fin), `nil` : le fichier entier.
    fileprivate var cutRange: (start: UInt64, end: UInt64)? {
        guard edit.file != nil, length >= 2, from > 0.05 || to < length - 0.05 else { return nil }
        return (UInt64(from * 1000), to < length - 0.05 ? UInt64(to * 1000) : 0)
    }

    fileprivate static func time(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    /// Durée lue dans le fichier choisi (import seulement).
    fileprivate func prepareCut() {
        guard let file = edit.file, listener == nil, let audio = try? AVAudioPlayer(data: file) else { return }
        listener = audio
        length = audio.duration
        to = audio.duration
    }

    /// Écoute de `at` jusqu'à la fin choisie ; la musique en cours s'arrête.
    fileprivate func listen(at: Double) {
        guard let listener else { return }
        if player.status.playing { player.pause() }
        listening?.cancel()
        listener.currentTime = max(0, at)
        listener.play()
        listening = Task { @MainActor in
            while !Task.isCancelled, listener.isPlaying, listener.currentTime < to {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            listener.pause()
            listening = nil
        }
    }

    fileprivate func stopListening() {
        listening?.cancel()
        listening = nil
        listener?.pause()
    }
}
