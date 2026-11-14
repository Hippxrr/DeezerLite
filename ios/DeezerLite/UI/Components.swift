import SwiftUI

extension Track: Identifiable {
    /// Lien deezer.com du titre (s'ouvre dans l'app Deezer ou le navigateur) ; aucun pour un fichier perso importé.
    var shareURL: URL? { id > 0 ? URL(string: "https://www.deezer.com/track/\(id)") : nil }
}

/// Lien deezer.com d'un album, d'une playlist ou d'un artiste (une playlist privée ne s'ouvre que pour son propriétaire).
func deezerLink(kind: String, id: UInt64) -> URL? {
    guard id > 0, ["album", "playlist", "artist"].contains(kind) else { return nil }
    return URL(string: "https://www.deezer.com/\(kind)/\(id)")
}

/// « Partager » dans le menu d'une carte (album, playlist, artiste).
struct ShareCardButton: View {
    let card: Card

    var body: some View {
        if let url = deezerLink(kind: card.kind, id: card.id) {
            ShareLink(item: url, subject: Text(card.title), message: Text(card.title)) {
                Label(tr("Partager"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// « Partager » : la feuille de partage d'iOS (Messages, WhatsApp, copier le lien…) avec le lien du titre.
struct ShareTrackButton: View {
    let track: Track

    var body: some View {
        if let url = track.shareURL {
            ShareLink(item: url, subject: Text(track.title), message: Text("\(track.title) – \(track.artist)")) {
                Label(tr("Partager"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Une page à ouvrir : playlist, album, artiste, mix, ou les titres aimés.
enum Route: Hashable {
    case detail(kind: String, id: UInt64, title: String)
    case mix(key: String, title: String)
    case loved

    init?(_ card: Card) {
        switch card.kind {
        case "loved": self = .loved
        case "playlist", "album", "artist": self = .detail(kind: card.kind, id: card.id, title: card.title)
        default:
            guard !card.key.isEmpty else { return nil }
            self = .mix(key: card.key, title: card.title)
        }
    }
}

private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue: (Route) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Ouvre une page dans l'onglet courant (aussi depuis un menu contextuel).
    var openRoute: (Route) -> Void {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}

/// Bouton qui s'enfonce légèrement sous le doigt (animation courte, rien en continu).
/// Comme les boutons d'iOS dans une liste, l'effet attend un court instant : un doigt posé pour faire défiler
/// n'enfonce plus la carte ou la ligne, et l'aperçu de l'appui long n'est plus pris pendant l'effet (grisé, trop petit).
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var shown = false
    /// Délai avant l'effet : sous ce seuil, le défilement a presque toujours déjà pris la main.
    private static let delay: Duration = .milliseconds(80)

    var body: some View {
        configuration.label
            .scaleEffect(shown ? 0.97 : 1)
            .opacity(shown ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: shown)
            .task(id: configuration.isPressed) {
                guard configuration.isPressed else {
                    shown = false
                    return
                }
                try? await Task.sleep(for: Self.delay)
                if !Task.isCancelled { shown = true }
            }
    }
}

extension ButtonStyle where Self == Pressable {
    static var pressable: Pressable { Pressable() }
}

/// Pochette chargée à la taille affichée (voir `CoverLoader`). En attendant la version nette, une version plus petite
/// déjà en mémoire est montrée dessous ; la nette arrive par-dessus en fondu (pas de saut d'image).
struct CoverView: View {
    let url: String?
    let side: CGFloat
    var radius: CGFloat = 6
    var round = false
    /// `false` : seulement ce qui est déjà en mémoire, aucun téléchargement (lecteur plein écran fermé).
    var load = true
    /// Pochette pleine largeur du grand lecteur : la version 1500 px (voir `CoverLoader.large`).
    var large = false
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var phase
    @State private var image: UIImage?
    /// Adresse de `image` : une vue réutilisée pour un autre élément ne garde pas l'ancienne pochette.
    @State private var imageURL: String?
    @State private var preview: UIImage?

    init(url: String?, side: CGFloat, radius: CGFloat = 6, round: Bool = false, load: Bool = true, large: Bool = false) {
        self.url = url
        self.side = side
        self.radius = radius
        self.round = round
        self.load = load
        self.large = large
        // Déjà en mémoire à la bonne taille : affichée dès la première image, sans case vide ni fondu.
        let pixels = large ? CoverLoader.large : Int(side * UIScreen.main.scale)
        let exact = url.flatMap { CoverLoader.shared.cached(url: $0, pixels: pixels) }
        _image = State(initialValue: exact)
        _imageURL = State(initialValue: exact == nil ? nil : url)
        _preview = State(initialValue: exact == nil ? url.flatMap { CoverLoader.shared.anyCached(url: $0) } : nil)
    }

    var body: some View {
        ZStack {
            Theme.card
            if let preview, image == nil || image !== preview {
                Image(uiImage: preview).resizable().scaledToFill()
            }
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity.animation(.easeOut(duration: 0.25)))
            } else if url == nil {
                FallbackArt() // titre sans pochette (MP3 importé…), comme sur le bureau
            }
        }
        .frame(width: side, height: side)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        // En arrière-plan : seulement ce qui est en mémoire ; la version nette est chargée au retour dans l'app.
        .task(id: "\(url ?? "")|\(load)|\(phase == .background)") {
            guard let url else { image = nil; imageURL = nil; preview = nil; return }
            if imageURL != url { image = nil; imageURL = nil }
            let loader = CoverLoader.shared
            let pixels = large ? CoverLoader.large : Int(side * scale)
            if let hit = loader.cached(url: url, pixels: pixels) {
                image = hit
                imageURL = url
                preview = nil
                return
            }
            if image == nil { preview = loader.anyCached(url: url) }
            guard load, phase != .background, let sharp = await loader.image(url: url, pixels: pixels) else { return }
            image = sharp
            imageURL = url
        }
    }
}

/// Pochette de remplacement (document violet), la même que sur la version bureau.
struct FallbackArt: View {
    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 512
            ZStack {
                DocumentShape(k: k)
                    .fill(LinearGradient(colors: [Color(red: 0.84, green: 0.69, blue: 1), Color(red: 0.54, green: 0.27, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                    .overlay(DocumentShape(k: k).stroke(Color(red: 0.43, green: 0.16, blue: 0.85).opacity(0.55), lineWidth: max(1, 5 * k)))
                    .shadow(color: Color(red: 0.1, green: 0.02, blue: 0.21).opacity(0.5), radius: 14 * k, y: 14 * k)
                FoldShape(k: k)
                    .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.86, blue: 1), Color(red: 0.65, green: 0.4, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }

    /// Feuille au coin replié (repère 512 x 512 de l'icône du bureau).
    private struct DocumentShape: Shape {
        let k: CGFloat
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 136 * k, y: 52 * k))
            p.addLine(to: CGPoint(x: 300 * k, y: 52 * k))
            p.addLine(to: CGPoint(x: 404 * k, y: 156 * k))
            p.addLine(to: CGPoint(x: 404 * k, y: 428 * k))
            p.addQuadCurve(to: CGPoint(x: 376 * k, y: 456 * k), control: CGPoint(x: 404 * k, y: 456 * k))
            p.addLine(to: CGPoint(x: 136 * k, y: 456 * k))
            p.addQuadCurve(to: CGPoint(x: 108 * k, y: 428 * k), control: CGPoint(x: 108 * k, y: 456 * k))
            p.addLine(to: CGPoint(x: 108 * k, y: 80 * k))
            p.addQuadCurve(to: CGPoint(x: 136 * k, y: 52 * k), control: CGPoint(x: 108 * k, y: 52 * k))
            p.closeSubpath()
            return p
        }
    }

    private struct FoldShape: Shape {
        let k: CGFloat
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 300 * k, y: 52 * k))
            p.addLine(to: CGPoint(x: 300 * k, y: 128 * k))
            p.addQuadCurve(to: CGPoint(x: 328 * k, y: 156 * k), control: CGPoint(x: 300 * k, y: 156 * k))
            p.addLine(to: CGPoint(x: 404 * k, y: 156 * k))
            p.closeSubpath()
            return p
        }
    }
}

/// Barres animées du titre en cours (animation système, arrêtée pendant la pause).
struct PlayingBars: View {
    let playing: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.accent)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing)
    }
}

/// Ligne de titre : appui = lecture de la liste à partir de ce titre ; appui long = actions.
struct TrackRow: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @State private var downloadStatus = TrackDownloadStatus()
    let track: Track
    let list: [Track]
    let index: Int
    var showCover = true
    /// Appelé à la lecture (recherche : ajoute le titre à l'historique).
    var onPlay: (() -> Void)?
    /// Appelé quand on ouvre l'album ou un artiste depuis le menu (recherche : ils rejoignent l'historique,
    /// comme sur la version bureau ; le titre, lui, n'a pas été lancé).
    var onOpen: ((Card) -> Void)?
    /// Dans une de ses playlists : « Retirer de la playlist ».
    var onRemove: (() -> Void)?
    /// `false` dans une rangée qui défile à l'horizontale : le glissement y fait défiler, il ne met pas en file.
    var swipeToQueue = true
    /// Glissement vers la droite : au-delà du seuil, le titre passe juste après celui en cours.
    @State private var swipe: CGFloat = 0
    @State private var queued = 0
    /// Un glissement vient d'avoir lieu : l'appui qui le termine ne lance pas le titre.
    @State private var swiped = false
    private static let swipeThreshold: CGFloat = 80

    /// État de téléchargement de CE titre. Juste après un changement de titre de la ligne, l'état suivi est encore
    /// celui de l'ancien : on lit alors directement celui du lecteur (pour cet affichage seulement).
    private var downloadUpdate: DownloadUpdate? {
        downloadStatus.id == track.id ? downloadStatus.update : player.downloadStates[track.id]
    }

    private var isDownloaded: Bool {
        downloadStatus.id == track.id ? downloadStatus.downloaded : player.downloadedIds.contains(track.id)
    }

    private func openAlbum() {
        onOpen?(Card(kind: "album", id: track.albumId, title: track.album, subtitle: track.artist, coverUrl: track.coverUrl, owned: false, key: ""))
        openRoute(.detail(kind: "album", id: track.albumId, title: track.album))
    }

    /// Plus grand déplacement du doigt pendant le glissement en cours.
    @State private var maxSwipe: CGFloat = 0
    /// Sous ce déplacement, un « glissement » terminé est en fait un appui où le doigt a un peu bougé.
    private static let tapSlop: CGFloat = 16

    private func activate() {
        guard !track.unavailable else { return }
        onPlay?()
        player.play(list, at: index)
    }

    /// Titre pas encore sorti : sa date de sortie ; retiré : « Indisponible ».
    private var unavailableLabel: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        if let raw = track.releaseDate, let date = parser.date(from: String(raw.prefix(10))), date > Date() {
            return tr("Sortie le %@", date.formatted(.dateTime.day().month(.abbreviated)))
        }
        return tr("Indisponible")
    }

    private func drag(_ dx: CGFloat) {
        swiped = true
        let raw = max(0, dx)
        maxSwipe = max(maxSwipe, raw)
        // Résistance au-delà du seuil.
        swipe = raw <= Self.swipeThreshold ? raw : Self.swipeThreshold + (raw - Self.swipeThreshold) * 0.3
    }

    /// `completed` : le doigt a été levé (et non un geste annulé par le défilement ou un appel).
    private func release(completed: Bool) {
        // Aucun glissement n'avait commencé (geste refusé dès le départ) : l'appui du bouton s'en occupe.
        guard swiped else { return }
        let wasTap = completed && maxSwipe < Self.tapSlop
        maxSwipe = 0
        if swipe >= Self.swipeThreshold {
            player.queueAdd([track], next: true)
            queued += 1
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipe = 0 }
        if wasTap {
            // Le doigt a glissé de quelques points pendant l'appui : le geste a pris la main et le bouton n'a rien
            // reçu. C'était bien un appui, donc on lance le titre (avant, il ne se passait rien).
            swiped = false
            activate()
            return
        }
        // L'appui du bouton arrive juste après la fin du geste : on l'ignore encore un court instant.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            swiped = false
        }
    }

    private func openArtist(_ a: ArtistRef) {
        // Pas encore d'image : elle sera reprise de la page de l'artiste à son ouverture.
        onOpen?(Card(kind: "artist", id: a.id, title: a.name, subtitle: "", coverUrl: nil, owned: false, key: ""))
        openRoute(.detail(kind: "artist", id: a.id, title: a.name))
    }

    var body: some View {
        let isCurrent = player.current?.id == track.id
        Button {
            guard !swiped else { return }
            activate()
        } label: {
            HStack(spacing: 12) {
                if showCover {
                    // Pochette à jour : réparée par le cœur si celle de la liste n'existe plus chez Deezer. Titre
                    // téléchargé (pochette enregistrée sur le téléphone, déjà réparée au téléchargement) : la sienne
                    // d'abord, sinon une adresse Internet la remplacerait et resterait vide hors ligne.
                    let saved = track.coverUrl.flatMap { $0.hasPrefix("http") ? nil : $0 }
                    CoverView(url: saved ?? player.coverFixes[track.id] ?? (isCurrent ? player.current?.coverUrl : nil) ?? track.coverUrl, side: 48, radius: 8)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.5))
                                PlayingBars(playing: player.status.playing)
                            }
                        }
                } else {
                    ZStack {
                        if isCurrent {
                            PlayingBars(playing: player.status.playing)
                        } else {
                            Text("\(index + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(isCurrent ? Theme.accent : .primary)
                    Text(track.unavailable ? unavailableLabel : track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let update = downloadUpdate {
                    if update.state == .downloading || update.state == .queued {
                        ProgressView(value: update.progress).controlSize(.small)
                    } else if update.state == .failed {
                        Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Theme.accent)
                }
                if player.lovedIds.contains(track.id) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.accent).transition(.scale.combined(with: .opacity))
                }
                Text(formatTime(Double(track.durationS))).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.2), value: isCurrent)
            // Pas encore sorti (ou retiré) : grisé, et un appui ne fait rien.
            .opacity(track.unavailable ? 0.4 : 1)
        }
        .buttonStyle(.pressable)
        .disabled(track.unavailable)
        // Aperçu de l'appui long aux coins arrondis, comme dans les apps d'Apple (au lieu d'un rectangle découpé net).
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
        .offset(x: swipe)
        .background(alignment: .leading) {
            // Révélé sous la ligne pendant le glissement ; s'allume une fois le seuil passé.
            if swipe > 0 {
                let ready = swipe >= Self.swipeThreshold
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ready ? Theme.onAccent : .primary)
                    .scaleEffect(ready ? 1.1 : 0.9)
                    .frame(width: max(swipe - 8, 0), alignment: .center)
                    .frame(maxHeight: .infinity)
                    .background(ready ? Theme.accent : Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .animation(.easeOut(duration: 0.15), value: ready)
            }
        }
        .modifier(SwipeRight(enabled: swipeToQueue && !track.unavailable, onChanged: drag, onEnded: { release(completed: $0) }))
        .sensoryFeedback(.impact(weight: .medium), trigger: queued)
        .sensoryFeedback(.selection, trigger: swipe >= Self.swipeThreshold) { _, ready in ready }
        .contextMenu {
            // Comparé avant d'être redessiné : la progression du téléchargement (toutes les 0,5 s), un play/pause ou
            // un changement d'état de la ligne ne reconstruisent plus le menu pendant qu'il est ouvert. Reconstruit
            // à ce moment-là, il pouvait ignorer l'appui sur « Télécharger » ou « Supprimer le téléchargement ».
            TrackMenu(track: track,
                      downloaded: isDownloaded,
                      downloadState: downloadUpdate?.state,
                      liked: player.lovedIds.contains(track.id),
                      canRemove: onRemove != nil,
                      onRemove: { onRemove?() },
                      onOpenAlbum: openAlbum,
                      onOpenArtist: openArtist)
                .equatable()
        }
        .task(id: track.id) { player.observeDownloads(downloadStatus, for: track.id) }
    }
}

/// Menu de l'appui long sur un titre. Ses actions passent par `Player` (rien ne dépend de l'état de la ligne au moment
/// où il a été construit) ; il n'est reconstruit que si ce qu'il affiche change vraiment.
private struct TrackMenu: View, Equatable {
    /// Ce que le menu affiche, en valeurs simples : c'est la seule chose comparée.
    private struct Key: Equatable, Sendable {
        let trackId: Int64
        let albumId: UInt64
        let downloaded: Bool
        /// 0 : rien, 1 : en attente ou en cours, 2 : échec (la progression n'apparaît pas dans le menu).
        let state: Int8
        let liked: Bool
        let canRemove: Bool
    }

    @Environment(Player.self) private var player
    private let key: Key
    let track: Track
    let downloaded: Bool
    let downloadState: DownloadState?
    let liked: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    let onOpenAlbum: () -> Void
    let onOpenArtist: (ArtistRef) -> Void

    init(track: Track, downloaded: Bool, downloadState: DownloadState?, liked: Bool, canRemove: Bool,
         onRemove: @escaping () -> Void, onOpenAlbum: @escaping () -> Void, onOpenArtist: @escaping (ArtistRef) -> Void) {
        self.track = track
        self.downloaded = downloaded
        self.downloadState = downloadState
        self.liked = liked
        self.canRemove = canRemove
        self.onRemove = onRemove
        self.onOpenAlbum = onOpenAlbum
        self.onOpenArtist = onOpenArtist
        let state: Int8 = switch downloadState {
        case .queued, .downloading: 1
        case .failed: 2
        default: 0
        }
        key = Key(trackId: track.id, albumId: track.albumId, downloaded: downloaded, state: state, liked: liked, canRemove: canRemove)
    }

    nonisolated static func == (a: TrackMenu, b: TrackMenu) -> Bool {
        a.key == b.key
    }

    var body: some View {
        Button { player.queueAdd([track], next: true) } label: { Label(tr("Lire ensuite"), systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.queueAdd([track], next: false) } label: { Label(tr("Ajouter à la file"), systemImage: "text.append") }
        Button { player.playlistTrack = track } label: { Label(tr("Ajouter à une playlist"), systemImage: "text.badge.plus") }
        if downloaded {
            Button(role: .destructive) { player.removeDownload(track.id) } label: { Label(tr("Supprimer le téléchargement"), systemImage: "trash") }
        } else {
            switch downloadState {
            case .failed:
                Button { player.download([track]) } label: { Label(tr("Réessayer"), systemImage: "arrow.clockwise") }
                Button(role: .destructive) { player.cancelDownload(track.id) } label: {
                    Label(tr("Annuler le téléchargement"), systemImage: "xmark.circle")
                }
            case .queued, .downloading:
                Button { player.cancelDownload(track.id) } label: { Label(tr("Annuler le téléchargement"), systemImage: "xmark.circle") }
            default:
                Button { player.download([track]) } label: { Label(tr("Télécharger"), systemImage: "arrow.down.circle") }
            }
        }
        if canRemove {
            Button(role: .destructive, action: onRemove) { Label(tr("Retirer de la playlist"), systemImage: "minus.circle") }
        }
        Button { player.creditsTrack = track } label: { Label(tr("Voir les crédits"), systemImage: "person.2") }
        ShareTrackButton(track: track)
        Button { player.setLiked(track, !liked) } label: {
            Label(liked ? tr("Retirer des titres aimés") : tr("J'aime"), systemImage: liked ? "heart.slash" : "heart")
        }
        if track.albumId != 0 {
            Button(action: onOpenAlbum) { Label(tr("Aller à l'album"), systemImage: "square.stack") }
        }
        let artists = track.artistLinks
        if artists.count == 1, let a = artists.first {
            Button { onOpenArtist(a) } label: { Label(tr("Aller à l'artiste"), systemImage: "music.mic") }
        } else if artists.count > 1 {
            // Feat : un sous-menu avec chaque artiste crédité.
            Menu {
                ForEach(artists, id: \.id) { a in
                    Button { onOpenArtist(a) } label: { Text(a.name) }
                }
            } label: { Label(tr("Aller à l'artiste"), systemImage: "music.mic") }
        }
    }
}

/// Carte d'une rangée horizontale (playlist, album, artiste, mix).
struct CardView: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    let card: Card
    var side: CGFloat = 148
    /// Appelé à l'ouverture (recherche : ajoute la carte à l'historique).
    var onOpen: ((Card) -> Void)?

    var body: some View {
        Button {
            onOpen?(card)
            if let route = Route(card) { openRoute(route) }
        } label: {
            VStack(alignment: card.kind == "artist" ? .center : .leading, spacing: 8) {
                // Pas d'ombre : dans une rangée qui défile, chaque ombre coûte un rendu à part.
                if let url = player.coverURL(card) {
                    CoverView(url: url, side: side, radius: Theme.radius, round: card.kind == "artist")
                } else if card.kind == "loved" {
                    LovedArt(side: side)
                } else {
                    CoverView(url: nil, side: side, radius: Theme.radius, round: card.kind == "artist")
                }
                VStack(alignment: card.kind == "artist" ? .center : .leading, spacing: 2) {
                    Text(card.kind == "loved" ? player.lovedTitle : card.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !card.subtitle.isEmpty {
                        Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                // Toute la largeur de la carte, même sous un titre court.
                .frame(maxWidth: .infinity, alignment: card.kind == "artist" ? .center : .leading)
            }
            .frame(width: side)
            // Toute la carte réagit, espaces vides compris (avant : seulement la pochette et les lettres du texte).
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contextMenu {
            DownloadCollectionMenu(card: card)
            PinMenu(card: card)
            CoverMenu(card: card)
            ShareCardButton(card: card)
            DeletePlaylistMenu(card: card)
        }
    }
}

/// Téléchargement d'une collection complète depuis l'appui long sur sa carte.
struct DownloadCollectionMenu: View {
    @Environment(Player.self) private var player
    let card: Card

    var body: some View {
        if ["album", "playlist", "loved"].contains(card.kind) {
            let downloaded = player.downloadedCollection(kind: card.kind, id: card.id) != nil
            let preparing = player.isPreparingDownload(card)
            let subject = card.kind == "album" ? "l’album" : card.kind == "loved" ? "les titres aimés" : "la playlist"
            if preparing {
                // Déjà demandé, la liste des titres arrive de Deezer : pas de second lancement.
                Button {} label: { Label(tr("Préparation du téléchargement…"), systemImage: "hourglass") }
                    .disabled(true)
            } else {
                Button(role: downloaded ? .destructive : nil) { player.toggleDownload(card) } label: {
                    Label(tr(downloaded ? "Supprimer \(subject) des téléchargements" : "Télécharger \(subject)"),
                          systemImage: downloaded ? "trash" : "arrow.down.circle")
                }
            }
        }
    }
}

/// « Changer la pochette… » (sur ce téléphone seulement) et « Pochette d'origine », pour une playlist ou les titres aimés.
struct CoverMenu: View {
    @Environment(Player.self) private var player
    let card: Card

    var body: some View {
        if CustomCovers.key(card) != nil {
            Button { player.chooseCover(for: card) } label: { Label(tr("Changer la pochette…"), systemImage: "photo") }
            if player.hasCustomCover(card) {
                Button { player.removeCustomCover(card) } label: { Label(tr("Pochette d'origine"), systemImage: "arrow.uturn.backward") }
            }
        }
    }
}

/// « Épingler sur l'accueil » / « Retirer de l'accueil » (pas pour les titres aimés, déjà sur l'accueil).
struct PinMenu: View {
    @Environment(Player.self) private var player
    let card: Card

    var body: some View {
        if card.kind != "loved", Route(card) != nil {
            let pinned = player.isPinned(card)
            Button { withAnimation { player.togglePin(card) } } label: {
                Label(pinned ? tr("Retirer de l'accueil") : tr("Épingler sur l'accueil"), systemImage: pinned ? "pin.slash" : "pin")
            }
        }
    }
}

/// « Renommer… » pour les titres aimés (sur ce téléphone seulement).
struct RenameLovedMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        Button { player.renamingLoved = true } label: { Label(tr("Renommer…"), systemImage: "pencil") }
    }
}

/// Image des titres aimés : cœur sur dégradé violet.
struct LovedArt: View {
    let side: CGFloat
    var radius: CGFloat = Theme.radius

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: side * 0.32, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: side, height: side)
            .background(Theme.accent,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Rangée horizontale avec un titre.
struct ShelfRow: View {
    let title: String
    let cards: [Card]
    /// Appui long sur le titre : masquer cette catégorie de l'accueil.
    var hideLabel: String?
    var onHide: (() -> Void)?
    var onOpen: ((Card) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).padding(.horizontal, 16)
                .contextMenu {
                    if let onHide, let hideLabel {
                        Button(role: .destructive, action: onHide) { Label(tr("Masquer « %@ » de l'accueil", hideLabel), systemImage: "eye.slash") }
                    }
                }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cards.indices, id: \.self) { i in CardView(card: cards[i], onOpen: onOpen) }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// Silhouette fixe affichée pendant le premier chargement (aucune animation : rien ne tourne pour rien).
struct SkeletonShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.card).frame(width: 160, height: 20).padding(.horizontal, 16)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card).frame(width: 148, height: 148)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.card).frame(width: 110, height: 12)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct SkeletonRows: View {
    var count = 8

    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.card).frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.card).frame(width: 110, height: 10)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Ligne en carte, au format de « Titres aimés » sur l'accueil : image, titre, détail, icône à droite.
struct ItemRow<Art: View>: View {
    let title: String
    let subtitle: String
    /// Icône à droite ; `nil` : aucune.
    var trailing: String? = "chevron.right"
    @ViewBuilder let art: () -> Art

    var body: some View {
        HStack(spacing: 14) {
            art()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing)
                    .font(trailing == "chevron.right" ? .caption.weight(.semibold) : .subheadline)
                    .foregroundStyle(trailing == "chevron.right" ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Theme.accent))
            }
        }
        .padding(10)
        .surface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Image d'une carte : pochette (perso ou Deezer), cœur des titres aimés, ou rond pour un artiste.
struct CardArt: View {
    @Environment(Player.self) private var player
    let card: Card
    var side: CGFloat = 64

    var body: some View {
        if let url = player.coverURL(card) {
            CoverView(url: url, side: side, radius: 10, round: card.kind == "artist")
        } else if card.kind == "loved" {
            LovedArt(side: side, radius: 10)
        } else {
            CoverView(url: nil, side: side, radius: 10, round: card.kind == "artist")
        }
    }
}

/// Playlist, album, artiste en carte : appui = ouvrir ; appui long = télécharger, épingler, changer la pochette.
struct CardRow: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    let card: Card
    /// Sur l'accueil : « Réorganiser l'accueil » dans le menu.
    var onReorder: (() -> Void)?

    var body: some View {
        Button {
            if let route = Route(card) { openRoute(route) }
        } label: {
            ItemRow(title: card.kind == "loved" ? player.lovedTitle : card.title, subtitle: card.subtitle) { CardArt(card: card) }
        }
        .buttonStyle(.pressable)
        .contextMenu {
            DownloadCollectionMenu(card: card)
            PinMenu(card: card)
            CoverMenu(card: card)
            ShareCardButton(card: card)
            if let onReorder {
                Button(action: onReorder) { Label(tr("Réorganiser l'accueil"), systemImage: "arrow.up.arrow.down") }
            }
            DeletePlaylistMenu(card: card)
        }
    }
}

/// Image de Flow : la pochette choisie sur le téléphone, sinon une vague sur la couleur du thème.
struct FlowArt: View {
    @Environment(Player.self) private var player
    var side: CGFloat = 64

    var body: some View {
        if let url = player.flowCover {
            CoverView(url: url, side: side, radius: 10)
        } else {
            wave
        }
    }

    private var wave: some View {
        Image(systemName: "waveform")
            .font(.system(size: side * 0.38, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: side, height: side)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Glissement d'une ligne vers la droite, sans gêner le défilement de la liste.
/// Un `DragGesture` posé sur chaque ligne entre en concurrence avec le défilement depuis iOS 18 :
/// la liste peut rester bloquée un moment avant de défiler. Ici, un geste UIKit qui ne démarre
/// que si le doigt part nettement vers la droite : un mouvement vertical est laissé tout entier à la liste.
private struct SwipeRight: ViewModifier {
    let enabled: Bool
    let onChanged: (CGFloat) -> Void
    /// `true` : doigt levé ; `false` : geste annulé (défilement, appel…).
    let onEnded: (Bool) -> Void
    /// iOS 17 : le glissement a démarré, la ligne suit le doigt même s'il revient.
    @State private var active = false
    /// Doigt posé : revient à `false` même si le système annule le geste (appel, Centre de contrôle), sans `onEnded`.
    @GestureState private var touching = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 18.0, *) {
            content.gesture(RightPan(onChanged: onChanged, onEnded: onEnded))
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .global)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { v in
                        let dx = v.translation.width, dy = v.translation.height
                        // Parti du bord gauche : c'est le geste « revenir en arrière », pas « lire ensuite ».
                        guard active || v.startLocation.x >= 30 else { return }
                        guard active || (dx > 0 && dx > abs(dy) * 1.8) else { return }
                        active = true
                        onChanged(dx)
                    }
                    .onEnded { _ in
                        guard active else { return }
                        active = false
                        onEnded(true)
                    }
            )
            .onChange(of: touching) { _, on in
                guard !on else { return }
                // Geste annulé : la ligne revient en place (une fin normale a déjà remis `active` à faux).
                Task { @MainActor in
                    await Task.yield()
                    if active {
                        active = false
                        onEnded(false)
                    }
                }
            }
        }
    }
}

@available(iOS 18.0, *)
private struct RightPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: onChanged(pan.translation(in: pan.view).x)
        case .ended: onEnded(true)
        case .cancelled, .failed: onEnded(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Bord gauche de l'écran laissé au geste système « revenir en arrière » (même largeur que celle d'iOS).
        private static let systemEdge: CGFloat = 30

        /// Démarre seulement vers la droite, bien plus à l'horizontale qu'à la verticale, et pas depuis le bord gauche :
        /// sinon revenir en arrière sur une page de playlist ajoutait le titre sous le doigt à la file.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            if let window = pan.view?.window {
                let start = pan.location(in: window).x - pan.translation(in: window).x
                if start < Self.systemEdge { return false }
            }
            let v = pan.velocity(in: pan.view)
            return v.x > 0 && v.x > abs(v.y) * 1.8
        }

        /// Le geste « retour » d'iOS depuis le bord passe toujours avant celui-ci.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            other is UIScreenEdgePanGestureRecognizer
        }
    }
}

/// iOS 26 : « revenir en arrière » se déclenche aussi en glissant depuis le milieu de l'écran, et prenait la place de
/// « Lire ensuite » sur les lignes. Ce geste-là est coupé pour la pile de navigation qui contient cette vue ; le retour
/// depuis le bord gauche reste. Posée en fond de la page racine de chaque onglet.
struct EdgeOnlyBack: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            disable()
            // La pile n'est pas toujours rattachée au premier passage : nouvel essai juste après.
            DispatchQueue.main.async { [weak self] in self?.disable() }
        }

        private func disable() {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                var r: UIResponder? = self
                while let next = r {
                    if let nav = next as? UINavigationController {
                        nav.interactiveContentPopGestureRecognizer?.isEnabled = false
                        return
                    }
                    r = next.next
                }
            }
            #endif
        }
    }
}
