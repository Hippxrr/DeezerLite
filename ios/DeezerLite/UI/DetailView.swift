import SwiftUI

/// Tri d'une liste de titres (mémorisé par type de page : playlist, album, titres aimés…).
enum TrackSort: String, CaseIterable {
    case standard, added, release, title, artist, album, duration

    var label: String {
        switch self {
        case .standard: tr("Ordre d'origine")
        case .added: tr("Date d'ajout")
        case .release: tr("Date de sortie")
        case .title: tr("Titre")
        case .artist: tr("Artiste")
        case .album: tr("Album")
        case .duration: tr("Durée")
        }
    }

    /// Les deux sens proposés pour ce critère ; le premier est celui par défaut.
    var directions: (String, String) {
        switch self {
        case .standard: (tr("Ordre normal"), tr("Ordre inversé"))
        case .added: (tr("Ajoutés récemment d'abord"), tr("Ajoutés il y a longtemps d'abord"))
        case .release: (tr("Plus récents d'abord"), tr("Plus anciens d'abord"))
        case .title, .artist, .album: (tr("De A à Z"), tr("De Z à A"))
        case .duration: (tr("Plus courts d'abord"), tr("Plus longs d'abord"))
        }
    }

    /// `reversed` : le second sens de `directions`.
    func apply(_ tracks: [Track], reversed: Bool) -> [Track] {
        let sorted: [Track] = switch self {
        case .standard: tracks
        case .added: tracks.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .release: tracks.sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
        case .title: tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: tracks.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .album: tracks.sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
        case .duration: tracks.sorted { $0.durationS < $1.durationS }
        }
        return reversed ? Array(sorted.reversed()) : sorted
    }
}

/// Dernier tri calculé d'une page : refait seulement si la liste, le critère ou le sens changent
/// (trier 3 000 titres par nom prend plusieurs dizaines de millisecondes ; la page se redessine bien plus souvent).
final class SortedTracks {
    private var key = ""
    private var value: [Track] = []

    func get(_ key: String, _ make: () -> [Track]) -> [Track] {
        if key != self.key {
            value = make()
            self.key = key
        }
        return value
    }
}

/// Page d'une playlist, d'un album, d'un artiste, d'un mix ou des titres aimés.
struct DetailView: View {
    @Environment(Player.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let route: Route
    @State private var detail: Detail?
    @State private var failed = false
    /// Couleur dominante de la pochette : dégradé derrière l'en-tête.
    @State private var tint: Color = .clear
    @State private var query = ""
    @State private var sorted = SortedTracks()
    /// Champ de recherche affiché seulement après un appui sur la loupe.
    @State private var searching = false
    /// Ligne de la liste en haut de l'écran (suivie par la vue défilante).
    @State private var scrollIndex: Int?
    /// Dernière position dans la liste complète (hors recherche tapée) : celle remise à l'ouverture et à la fermeture de
    /// la loupe. Le champ de recherche reconstruit toute la page, qui revenait sinon en haut.
    @State private var keptIndex: Int?
    @State private var searchToggledAt = Date.distantPast
    /// Confirmation avant de supprimer le téléchargement de la collection (corbeille de la barre du haut).
    @State private var confirmRemoveDownload = false
    @AppStorage private var sortRaw: String
    @AppStorage private var sortReversed: Bool

    init(route: Route) {
        self.route = route
        // Page récente ou copie téléchargée : affichée tout de suite, puis actualisée si Deezer répond.
        _detail = State(initialValue: Player.shared.cachedDetail(route))
        let kind: String = switch route {
        case .detail(let k, _, _): k
        case .mix: "mix"
        case .loved: "loved"
        }
        _sortRaw = AppStorage(wrappedValue: TrackSort.standard.rawValue, "sort.\(kind)")
        _sortReversed = AppStorage(wrappedValue: false, "sortReversed.\(kind)")
    }

    private var sort: TrackSort { TrackSort(rawValue: sortRaw) ?? .standard }

    /// Pochette affichée : la perso du téléphone si elle existe.
    private func coverURL(_ d: Detail) -> String? {
        player.coverURL(kind: d.kind, id: d.id, fallback: d.coverUrl)
    }

    /// La page sous forme de carte pour le menu de pochette (playlists et titres aimés seulement).
    private func coverCard(_ d: Detail) -> Card? {
        guard CustomCovers.key(kind: d.kind, id: d.id) != nil else { return nil }
        return Card(kind: d.kind, id: d.id, title: d.title, subtitle: d.subtitle, coverUrl: d.coverUrl, owned: d.owned, key: "")
    }

    /// La page sous forme de carte, pour l'épingler sur l'accueil (pas les titres aimés, déjà sur l'accueil).
    private var pinCard: Card? {
        guard let d = detail else { return nil }
        switch route {
        case .detail(let kind, let id, _):
            return Card(kind: kind, id: id, title: d.title, subtitle: d.subtitle, coverUrl: d.coverUrl, owned: d.owned, key: "")
        case .mix(let key, _):
            return Card(kind: "mix", id: 0, title: d.title, subtitle: d.subtitle, coverUrl: d.coverUrl, owned: false, key: key)
        case .loved:
            return nil
        }
    }

    /// Titres affichés : filtrés par la recherche, puis triés. « Lecture » joue cette liste-là.
    private func shown(_ d: Detail) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // La liste déjà triée est filtrée telle quelle : pas de nouveau tri à chaque lettre.
        guard !q.isEmpty else { return full(d) }
        return full(d).filter {
            $0.title.localizedStandardContains(q) || $0.artist.localizedStandardContains(q) || $0.album.localizedStandardContains(q)
        }
    }

    /// Toute la liste dans l'ordre choisi (gardée en mémoire, voir `SortedTracks`).
    private func full(_ d: Detail) -> [Track] {
        // Empreinte de tous les titres, dans l'ordre : une playlist réordonnée ou modifiée au milieu n'est plus confondue
        // avec l'ancienne (même nombre de titres, mêmes extrémités), qui restait affichée et jouée.
        var fingerprint = Hasher()
        for t in d.tracks { fingerprint.combine(t.id) }
        return sorted.get("\(d.kind)|\(d.id)|\(d.tracks.count)|\(fingerprint.finalize())|\(sortRaw)|\(sortReversed)") {
            sort.apply(d.tracks, reversed: sortReversed)
        }
    }

    /// Tris qui ont un sens pour cette page.
    private func sorts(_ d: Detail) -> [TrackSort] {
        TrackSort.allCases.filter { s in
            switch s {
            case .added: d.tracks.contains { $0.addedAt != nil }
            case .release: d.tracks.contains { $0.releaseDate != nil }
            case .album: d.kind != "album"
            default: true
            }
        }
    }

    private var pageTitle: String {
        route == .loved ? player.lovedTitle : detail?.title ?? title
    }

    /// Contenu de la page (à part de `body` : tout au même endroit dépassait ce que le compilateur sait vérifier).
    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let d = detail {
                    if d.kind == "artist" {
                        header(d, tracks: d.tracks)
                        artistBody(d)
                    } else {
                        // Toute la playlist dans l'ordre choisi : c'est elle qui part en lecture, même pendant une recherche
                        // (lancer un titre trouvé enchaîne avec la suite de la playlist, pas seulement les résultats).
                        let ordered = full(d)
                        let tracks = shown(d)
                        header(d, tracks: ordered)
                        if tracks.isEmpty && !query.isEmpty {
                            Text(tr("Aucun titre ne correspond à « %@ ».", query)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
                        }
                        // Numéros de piste seulement dans l'ordre de l'album.
                        trackList(tracks, in: ordered, numbered: d.kind == "album" && sort == .standard && !sortReversed && query.isEmpty,
                                  removable: d.kind == "playlist" && d.owned)
                    }
                } else if failed {
                    Text(tr("Impossible de charger la page.")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    skeletonHeader
                    SkeletonRows()
                }
            }
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.25), value: detail == nil)
        }
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        if let d = detail, ["album", "playlist", "loved"].contains(d.kind), !d.tracks.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                let downloaded = player.downloadedCollection(kind: d.kind, id: d.id) != nil
                // Télécharger : tout de suite. Supprimer : après confirmation (un appui accidentel effaçait tout).
                Button {
                    if downloaded { confirmRemoveDownload = true } else { player.toggleDownload(d) }
                } label: {
                    Image(systemName: downloaded ? "trash" : "arrow.down.circle")
                        .foregroundStyle(downloaded ? .red : .primary)
                }
                .accessibilityLabel(downloaded ? "Supprimer des téléchargements" : "Télécharger la collection")
            }
        }
        if let d = detail, let url = deezerLink(kind: d.kind, id: d.id) {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: url, subject: Text(d.title), message: Text(d.title)) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(tr("Partager"))
            }
        }
        if let card = pinCard {
            ToolbarItem(placement: .topBarTrailing) {
                let pinned = player.isPinned(card)
                Button { withAnimation { player.togglePin(card) } } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
            }
        }
        if let d = detail, d.kind != "artist", d.tracks.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { searching = true }
                } label: { Image(systemName: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Changer de critère repart dans son sens par défaut.
                    Picker(tr("Trier par"), selection: Binding(get: { sortRaw }, set: { sortRaw = $0; sortReversed = false })) {
                        ForEach(sorts(d), id: \.self) { s in Text(s.label).tag(s.rawValue) }
                    }
                    Picker(tr("Ordre"), selection: $sortReversed) {
                        Text(sort.directions.0).tag(false)
                        Text(sort.directions.1).tag(true)
                    }
                } label: {
                    Image(systemName: sort == .standard && !sortReversed ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                }
            }
        }
    }

    var body: some View {
        pageContent
        .scrollPosition(id: $scrollIndex, anchor: .top)
        .onChange(of: scrollIndex) { _, index in
            // Positions de la liste complète seulement (pas des résultats filtrés), et pas pendant la reconstruction.
            if query.isEmpty, Date().timeIntervalSince(searchToggledAt) > 0.5 { keptIndex = index }
        }
        .onChange(of: searching) {
            searchToggledAt = Date()
            let target = keptIndex
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                scrollIndex = target
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(colorScheme == .dark ? 0.75 : 0.3), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: tint)
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ListSearch(active: searching, text: $query, presented: $searching))
        .toolbar { pageToolbar }
        // Pochettes supprimées chez Deezer : vérifiées en arrière-plan, sans retarder l'affichage de la page.
        .task(id: detail?.tracks.count ?? 0) {
            if let d = detail, !d.offline { await player.checkCovers(d.tracks) }
        }
        .confirmationDialog("Supprimer le téléchargement ?", isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button(tr("Supprimer"), role: .destructive) {
                // Relu au moment de l'appui : la collection a pu être supprimée ailleurs entre-temps.
                if let d = detail, let collection = player.downloadedCollection(kind: d.kind, id: d.id) {
                    player.removeDownloadCollection(collection)
                    // Copie hors ligne affichée : ses titres n'existent plus. Rechargée depuis Deezer, ou page fermée
                    // sans réseau (avant, elle restait affichée et « Lecture » échouait).
                    if d.offline {
                        detail = nil
                        Task {
                            await load(force: true)
                            if detail == nil { dismiss() }
                        }
                    }
                }
            }
        } message: {
            Text("Les titres de « \(pageTitle) » seront supprimés de ce téléphone, sauf ceux qui font aussi partie d'une autre playlist ou d'un autre album téléchargé.")
        }
        .task { await load(force: false) }
        // Copie hors ligne : un titre supprimé de ce téléphone disparaît aussi de la page.
        .onChange(of: player.downloadedIds) { _, ids in
            guard detail?.offline == true else { return }
            detail?.tracks.removeAll { !ids.contains($0.id) }
        }
        .task(id: detail.flatMap(coverURL) ?? "") {
            guard let d = detail, let url = coverURL(d) else {
                if detail?.kind == "loved" { tint = Theme.accent }
                return
            }
            if let c = await CoverLoader.shared.color(url: url) { tint = Color(uiColor: c) }
        }
        .refreshable { await load(force: true) }
    }

    private var title: String {
        switch route {
        case .detail(_, _, let t), .mix(_, let t): t
        case .loved: player.lovedTitle
        }
    }

    private func load(force: Bool) async {
        let result = await player.detail(route, force: force)
        if result != nil || detail == nil { detail = result }
        failed = detail == nil
    }

    private var skeletonHeader: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card).frame(width: 220, height: 220)
            RoundedRectangle(cornerRadius: 6).fill(Theme.card).frame(width: 200, height: 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func header(_ d: Detail, tracks: [Track]) -> some View {
        VStack(spacing: 16) {
            Group {
                if let url = coverURL(d) {
                    CoverView(url: url, side: 220, radius: 20, round: d.kind == "artist")
                } else if d.kind == "loved" {
                    LovedArt(side: 220, radius: 20)
                } else {
                    CoverView(url: nil, side: 220, radius: 20, round: d.kind == "artist")
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
            // Appui long sur la pochette : la changer sur ce téléphone (playlists et titres aimés), renommer les titres aimés.
            .contextMenu {
                if d.kind == "loved" { RenameLovedMenu() }
                if let card = coverCard(d) { CoverMenu(card: card) }
            }
            VStack(spacing: 4) {
                Text(d.kind == "loved" ? player.lovedTitle : d.title).font(.title2.bold()).multilineTextAlignment(.center)
                if !d.subtitle.isEmpty { Text(d.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                // Nombre de titres et durée totale (playlists, albums, titres aimés, mixes).
                if d.kind != "artist", !d.tracks.isEmpty {
                    Text(Self.summary(d.tracks)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Button { player.play(tracks, at: 0) } label: {
                        Label(tr("Lecture"), systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundStyle(Theme.onAccent)
                            .surface(Capsule(), tint: Theme.accent)
                    }
                    Button {
                        if !player.shuffle { player.toggleShuffle() }
                        player.play(tracks, at: Int.random(in: 0..<tracks.count))
                    } label: {
                        Label(tr("Aléatoire"), systemImage: "shuffle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundStyle(.primary)
                            .surface(Capsule())
                    }
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// `tracks` : titres affichés ; `full` : liste lue (la même sans recherche, toute la playlist avec).
    private func trackList(_ tracks: [Track], in full: [Track], numbered: Bool, removable: Bool = false) -> some View {
        // Position de chaque titre affiché dans la liste complète (calculée seulement pendant une recherche).
        let position: [Int64: Int] = tracks.count == full.count ? [:]
            : Dictionary(full.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LazyVStack(spacing: 14) {
            ForEach(tracks.indices, id: \.self) { i in
                let track = tracks[i]
                TrackRow(track: track, list: full, index: position[track.id] ?? i, showCover: !numbered,
                         onRemove: removable ? { remove(track) } : nil)
            }
        }
        // Lignes repérées par la vue défilante (position gardée quand la loupe s'ouvre ou se ferme, voir `body`).
        .scrollTargetLayout()
        .padding(.horizontal, 16)
    }

    /// « 12 titres · 47 min » ou « 230 titres · 14 h 05 min ».
    static func summary(_ tracks: [Track]) -> String {
        let seconds = tracks.reduce(0) { $0 + Int($1.durationS) }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        let length = hours > 0 ? "\(hours) h \(String(format: "%02d", minutes)) min" : "\(max(minutes, seconds > 0 ? 1 : 0)) min"
        return "\(tracks.count > 1 ? tr("%@ titres", "\(tracks.count)") : tr("1 titre")) · \(length)"
    }

    /// Retiré de l'écran tout de suite ; remis à sa place si Deezer refuse.
    private func remove(_ track: Track) {
        guard let d = detail, let at = d.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) { detail?.tracks.remove(at: at) }
        Task {
            guard !(await player.removeFromPlaylist(d.id, track)) else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                if detail?.tracks.contains(where: { $0.id == track.id }) == false {
                    detail?.tracks.insert(track, at: min(at, detail?.tracks.count ?? 0))
                }
            }
        }
    }

    @ViewBuilder
    private func artistBody(_ d: Detail) -> some View {
        if !d.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Populaires")).font(.title3.bold()).padding(.horizontal, 16)
                let top = Array(d.tracks.prefix(10))
                trackList(top, in: top, numbered: false)
            }
        }
        if let latest = d.latest { ShelfRow(title: tr("Dernière sortie"), cards: [latest]) }
        if !d.albums.isEmpty { ShelfRow(title: tr("Discographie"), cards: d.albums) }
        if !d.related.isEmpty { ShelfRow(title: tr("Artistes similaires"), cards: d.related) }
    }
}

/// Recherche dans la liste : le champ n'existe qu'une fois ouvert par la loupe ; « Annuler » le referme et vide la recherche.
private struct ListSearch: ViewModifier {
    let active: Bool
    @Binding var text: String
    @Binding var presented: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .searchable(text: $text, isPresented: $presented, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("Rechercher dans la liste"))
                .onChange(of: presented) { _, open in if !open { text = "" } }
        } else {
            content
        }
    }
}
