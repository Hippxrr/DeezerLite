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
    /// Copie du fichier à envoyer, faite pour l'app (import seulement) : lue seulement à l'envoi, supprimée quand la
    /// fenêtre se ferme. Avant, tout le MP3 restait en mémoire plusieurs fois (gros mix : app fermée par iOS).
    let file: URL?
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
    /// Forme d'onde (une valeur de 0 à 1 par barre) et position de l'écoute en cours.
    @State private var peaks: [Float] = []
    /// Poignée de la découpe tenue : la fenêtre ne défile pas et ne se ferme pas en même temps.
    @State private var trimming = false
    @State private var playhead: Double?

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
                        // Façon iPhone : forme d'onde, cadre avec une poignée de chaque côté, trait de lecture pendant l'écoute.
                        TrimBar(peaks: peaks, length: length, from: $from, to: $to, playhead: playhead, dragging: $trimming,
                                onRelease: { start in listen(at: start ? from : max(from, to - 3)) },
                                onTap: { t in if t >= from && t < to { listen(at: t) } })
                            .frame(height: 56)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 6)
                        HStack {
                            Text("\(tr("Début")) \(Self.time(from))")
                            Spacer()
                            Text("\(tr("Fin")) \(Self.time(to))")
                        }
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Button(listening == nil ? tr("Écouter") : tr("Pause")) {
                            if listening == nil { listen(at: from) } else { stopListening() }
                        }
                    } header: {
                        Text(tr("Couper"))
                    } footer: {
                        Text(tr("%@ gardées. Lâche une poignée pour écouter à cet endroit.", Self.time(to - from)))
                    }
                    // Au moins 1 s gardée.
                    .onChange(of: from) { _, v in if v > to - 1 { from = max(0, to - 1) } }
                    .onChange(of: to) { _, v in if v < from + 1 { to = min(length, from + 1) } }
                }
            }
            .navigationTitle(edit.track == nil ? tr("Importer un MP3") : tr("Modifier le MP3"))
            .task { await prepareCut() }
            .onDisappear {
                stopListening()
                // Cadrage de la pochette ouvert par-dessus : la fenêtre n'est que cachée, le fichier sert encore (avant, il
                // était supprimé ici et « Importer » échouait ensuite).
                guard crop == nil else { return }
                if let file = edit.file { try? FileManager.default.removeItem(at: file) }
            }
            // Pendant l'envoi : pas de fermeture par glissement (le fichier serait supprimé).
            .interactiveDismissDisabled(sending || trimming)
            .scrollDisabled(trimming)
            .sensoryFeedback(.selection, trigger: trimming)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annuler")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.track == nil ? tr("Importer") : tr("Enregistrer")) {
                        sending = true
                        Task {
                            stopListening()
                            // Échec (réseau…) : la fenêtre reste ouverte avec le fichier, la découpe et ce qui a été saisi.
                            if await player.saveMp3(edit, title: title, artist: artist, album: album, cover: cover,
                                                    resetCover: resetCover, cut: cutRange) {
                                dismiss()
                            } else {
                                sending = false
                            }
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

    static func time(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    /// Durée et forme d'onde du fichier choisi (import seulement).
    fileprivate func prepareCut() async {
        // Relancé au retour du cadrage de la pochette : refait seulement si la forme d'onde n'était pas finie.
        guard let file = edit.file, peaks.isEmpty else { return }
        if listener == nil {
            guard let audio = try? AVAudioPlayer(contentsOf: file) else { return }
            listener = audio
            length = audio.duration
            to = audio.duration
        }
        // Débit variable sans en-tête de durée : celle d'AVAudioPlayer n'est qu'une estimation, la coupe tombait à côté.
        // Celle du son décodé est exacte (la même que pour la coupe).
        let (bars, seconds) = await waveform(of: file, bars: TrimBar.bars)
        guard !Task.isCancelled else { return }
        peaks = bars
        if seconds >= 2, abs(seconds - length) > 0.05 {
            let atEnd = to >= length - 0.05
            length = seconds
            to = atEnd ? seconds : min(to, seconds)
            from = min(from, max(0, to - 1))
        }
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
                playhead = listener.currentTime
                // 10 fois par seconde : assez pour suivre l'écoute, sans redessiner toute la fenêtre 25 fois par seconde.
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            listener.pause()
            listening = nil
            playhead = nil
        }
    }

    fileprivate func stopListening() {
        listening?.cancel()
        listening = nil
        playhead = nil
        listener?.pause()
    }
}

/// Forme d'onde d'un MP3 (le plus fort échantillon de chaque barre, de 0,12 à 1 ; racine : les passages calmes restent
/// visibles) et sa durée exacte en secondes. Lu par morceaux, hors du fil principal ; arrêté si la fenêtre se ferme.
/// Vide (et 0) si le fichier est illisible.
private func waveform(of url: URL, bars: Int) async -> ([Float], Double) {
    guard let file = try? AVAudioFile(forReading: url),
          file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { return ([], 0) }
    let total = file.length
    let seconds = Double(total) / file.processingFormat.sampleRate
    var out = [Float](repeating: 0, count: bars)
    var position: AVAudioFramePosition = 0
    while position < total, !Task.isCancelled, (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
        let n = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            for i in stride(from: 0, to: n, by: 8) {
                let bar = min(bars - 1, Int((position + AVAudioFramePosition(i)) * AVAudioFramePosition(bars) / total))
                out[bar] = max(out[bar], abs(samples[i]))
            }
        }
        position += AVAudioFramePosition(n)
    }
    guard let top = out.max(), top > 0 else { return ([], seconds) }
    return (out.map { max(0.12, ($0 / top).squareRoot()) }, seconds)
}

/// Découpe façon iPhone : barres de la forme d'onde, cadre clair entre deux poignées (début et fin, au moins 1 s
/// d'écart), trait blanc à la position de l'écoute. Un appui dans le cadre écoute à partir de là.
struct TrimBar: View {
    static let bars = 60
    let peaks: [Float]
    let length: Double
    @Binding var from: Double
    @Binding var to: Double
    let playhead: Double?
    /// Une poignée est tenue.
    @Binding var dragging: Bool
    /// Poignée lâchée (`true` : celle du début).
    let onRelease: (Bool) -> Void
    let onTap: (Double) -> Void
    /// Valeur de la poignée au début du glissement : elle suit le déplacement du doigt, sans sauter sous lui au toucher.
    @State private var dragStart: Double?
    /// Doigt posé sur une poignée : revient à `false` même si iOS interrompt le geste (sans `onEnded`).
    @GestureState private var held = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (t: Double) in CGFloat(t / max(length, 0.001)) * w }
            let time = { (px: CGFloat) in Double(min(max(px / max(w, 1), 0), 1)) * length }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    ForEach(0..<Self.bars, id: \.self) { i in
                        let v = peaks.isEmpty ? 0.12 : CGFloat(peaks[min(i, peaks.count - 1)])
                        let mid = (Double(i) + 0.5) / Double(Self.bars) * length
                        Capsule()
                            .fill(.white.opacity(mid < from || mid > to ? 0.3 : 0.9))
                            .frame(maxWidth: 4)
                            .frame(height: max(4, v * h))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: w, height: h)
                // Cadre : un trait en haut et un en bas, entre les deux poignées.
                ForEach([-4.0, h + 4], id: \.self) { y in
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: max(x(to) - x(from), 0), height: 3)
                        .position(x: (x(from) + x(to)) / 2, y: y)
                }
                if let playhead {
                    Capsule().fill(.white)
                        .frame(width: 3, height: h + 16)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .position(x: x(playhead), y: h / 2)
                        .allowsHitTesting(false)
                }
                handle(start: true, h: h)
                    .position(x: x(from), y: h / 2)
                    // Prioritaire : le défilement de la fenêtre ne prend pas le geste.
                    .highPriorityGesture(DragGesture(minimumDistance: 0)
                        .updating($held) { _, state, _ in state = true }
                        .onChanged { v in
                            let start = begin(from)
                            from = min(max(0, start + Double(v.translation.width / max(w, 1)) * length), to - 1)
                        }
                        .onEnded { _ in onRelease(true) })
                handle(start: false, h: h)
                    .position(x: x(to), y: h / 2)
                    .highPriorityGesture(DragGesture(minimumDistance: 0)
                        .updating($held) { _, state, _ in state = true }
                        .onChanged { v in
                            let start = begin(to)
                            to = max(min(length, start + Double(v.translation.width / max(w, 1)) * length), from + 1)
                        }
                        .onEnded { _ in onRelease(false) })
            }
            .coordinateSpace(.named("trim"))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named("trim")) { p in onTap(time(p.x)) }
            .onChange(of: held) { _, on in
                dragging = on
                if !on { dragStart = nil }
            }
        }
    }

    /// Début d'un glissement : retient la valeur de départ (une seule fois par geste).
    private func begin(_ value: Double) -> Double {
        if let dragStart { return dragStart }
        dragStart = value
        return value
    }

    private func handle(start: Bool, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(white: 0.91))
            .frame(width: 18, height: h + 12)
            .overlay {
                HStack(spacing: 2.5) {
                    ForEach(0..<2, id: \.self) { _ in Capsule().fill(Color(white: 0.56)).frame(width: 1.5, height: h * 0.4) }
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            // Zone d'appui élargie vers l'extérieur seulement (début vers la gauche, fin vers la droite) : poignées
            // l'une sur l'autre (long fichier, 1 s d'écart), chacune reste attrapable de son côté.
            .contentShape(Path(CGRect(x: start ? -24 : 0, y: -10, width: 42, height: h + 32)))
            .accessibilityElement()
            .accessibilityLabel(start ? tr("Début") : tr("Fin"))
            .accessibilityValue(Mp3EditView.time(start ? from : to))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                if start { from = min(max(0, from + step), to - 1) } else { to = max(min(length, to + step), from + 1) }
            }
    }
}
