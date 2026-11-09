import SwiftUI

/// Glisser verticalement n'importe où baisse le clavier. Le geste est posé sur la fenêtre et ne prend aucun appui : il
/// marche aussi sur une page vide (où la liste ne défile pas et ne reçoit rien), et les boutons restent utilisables.
private struct KeyboardDrag: UIViewRepresentable {
    let active: Bool
    let onDrag: () -> Void

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pan = UIPanGestureRecognizer()
        var onDrag: () -> Void = {}

        override init() {
            super.init()
            pan.addTarget(self, action: #selector(moved(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
        }

        @objc private func moved(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .changed else { return }
            let t = pan.translation(in: pan.view)
            if abs(t.y) > 12 && abs(t.y) > abs(t.x) { onDrag() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class Probe: UIView {
        var pan: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let pan else { return }
            pan.view?.removeGestureRecognizer(pan)
            window?.addGestureRecognizer(pan)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.pan = context.coordinator.pan
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        context.coordinator.onDrag = onDrag
        context.coordinator.pan.isEnabled = active
    }
}

struct SearchView: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var searching = false
    /// Recherche en attente pendant la frappe (remplacée à chaque lettre).
    @State private var pending: Task<Void, Never>?
    @State private var failed = false
    /// Clavier ouvert sur le champ de recherche.
    @FocusState private var typing: Bool
    /// Change à chaque nouvel appui sur l'onglet Recherche déjà ouvert : ouvre le clavier.
    var focusRequest = 0

    /// Largeur du mot « Annuler » dans la langue choisie.
    private var cancelWidth: CGFloat {
        let text = tr("Annuler") as NSString
        return text.size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width.rounded(.up) + 2
    }

    /// Champ de l'app plutôt que celui d'iOS (`searchable`) : celui-ci mettait la page dans son propre conteneur, au fond
    /// noir (le fond choisi ne se voyait pas), et glisser sur la page ne baissait pas son clavier.
    private var searchField: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("Titre, artiste, album"), text: $query)
                    .focused($typing)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        let q = query.trimmingCharacters(in: .whitespaces)
                        if !q.isEmpty { player.remember(.query(q)) }
                        run(after: .zero)
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 30, height: 40)
                    }
                    .accessibilityLabel(tr("Tout effacer"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 44)
            .surface(Capsule(), interactive: false, material: true)
            // Toujours présent, sa largeur va de 0 au mot entier : la bulle rétrécit d'autant, ils ne peuvent pas se chevaucher.
            Button(tr("Annuler")) {
                query = ""
                typing = false
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 10)
            .frame(width: typing ? cancelWidth + 10 : 0, alignment: .leading)
            .clipped()
            .opacity(typing ? 1 : 0)
            .allowsHitTesting(typing)
            .accessibilityHidden(!typing)
        }
        .animation(.easeOut(duration: 0.2), value: typing)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Fond de la page : ce qui défile passe dessous sans se mêler au champ.
        .background(Theme.background.ignoresSafeArea(edges: .top))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HistoryList { query = $0 }
                } else if failed {
                    Label(tr("Recherche impossible pour l'instant. Vérifie ta connexion."), systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let r = results {
                    if r.tracks.isEmpty && r.albums.isEmpty && r.artists.isEmpty && r.playlists.isEmpty {
                        Text(tr("Aucun résultat.")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    // Un artiste recherché : sa fiche en tête (photo, dernière sortie), puis ses titres et albums.
                    let top = topArtist(r)
                    if let top { TopArtist(card: top, onOpen: remember) }
                    // Nouveaux résultats : une nouvelle grille apparaît en fondu, à partir du début. Avec la même grille, le
                    // nombre de lignes changeait et les titres glissaient d'une colonne à l'autre, vers la droite.
                    if !r.tracks.isEmpty {
                        TrackPages(tracks: r.tracks, onOpen: remember)
                            .id("\(r.tracks.first?.id ?? 0)-\(r.tracks.count)")
                            .transition(.opacity)
                    }
                    if !r.albums.isEmpty { ShelfRow(title: tr("Albums"), cards: r.albums, onOpen: remember) }
                    if !r.playlists.isEmpty { ShelfRow(title: tr("Playlists"), cards: r.playlists, onOpen: remember) }
                    let others = r.artists.filter { $0.id != top?.id }
                    if !others.isEmpty { ShelfRow(title: tr("Artistes"), cards: others, onOpen: remember) }
                }
            }
            .padding(.vertical, 12)
        }
        // Glisser sur la page baisse le clavier, même si elle est trop courte pour défiler (sinon le geste ne faisait rien).
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.immediately)
        .modifier(ScrollWatch { _ in typing = false })
        // Page vide (rien de tapé, pas d'historique) : rien ne défile. Seulement clavier ouvert, pour ne rien gêner sinon.
        .background(KeyboardDrag(active: typing) { typing = false })
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .toolbar(.hidden, for: .navigationBar)
        // Résultats au fil de la frappe : la recherche part 300 ms après la dernière lettre (pas une requête par lettre).
        .onChange(of: query) { _, _ in run(after: .milliseconds(300)) }
        .onChange(of: focusRequest) {
            typing = true
            // Une page était ouverte par-dessus : le champ n'est atteignable qu'une fois revenu à la recherche.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                typing = true
            }
        }
    }

    private func remember(_ card: Card) { player.remember(.card(card)) }

    /// Artiste qui correspond à ce qui est tapé (« ninho » → Ninho ; rien pour un titre de chanson). Les artistes
    /// arrivent du plus suivi au moins suivi : à nom égal, c'est le plus connu qui est choisi, pas un homonyme.
    private func topArtist(_ r: SearchResults) -> Card? {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces) }
        let q = fold(query)
        return r.artists.first { fold($0.title) == q }
            ?? (q.count >= 3 ? r.artists.first { fold($0.title).hasPrefix(q) } : nil)
    }

    private func run(after delay: Duration) {
        pending?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = nil
            failed = false
            searching = false
            return
        }
        failed = false
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if results == nil { searching = true }
            let found = try? await player.core?.search(query: q)
            // Une frappe plus récente a pris le relais : ce résultat est périmé.
            guard !Task.isCancelled, q == query.trimmingCharacters(in: .whitespaces) else { return }
            failed = found == nil
            withAnimation(.easeOut(duration: 0.18)) { if let found { results = found } }
            searching = false
        }
    }
}

/// Fiche de l'artiste recherché : sa photo (appui = sa page), puis sa dernière sortie.
private struct TopArtist: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    let card: Card
    let onOpen: (Card) -> Void
    @State private var latest: Card?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { open(card) } label: {
                HStack(spacing: 16) {
                    CoverView(url: card.coverUrl, side: 76, round: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title).font(.title3.bold()).lineLimit(1)
                        Text(card.subtitle.isEmpty ? tr("Artiste") : card.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            if let latest {
                Divider()
                Button { open(latest) } label: {
                    HStack(spacing: 14) {
                        CoverView(url: latest.coverUrl, side: 84, radius: 10)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Dernière sortie"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(latest.title).font(.headline).lineLimit(2)
                            if !latest.subtitle.isEmpty {
                                Text(latest.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .transition(.opacity)
            }
        }
        .padding(14)
        .surface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        // Dernière sortie : lue sur la page de l'artiste (gardée en mémoire, reprise si on l'ouvre ensuite).
        .task(id: card.id) {
            latest = nil
            let page = await player.detail(.detail(kind: "artist", id: card.id, title: card.title), force: false)
            withAnimation(.easeOut(duration: 0.2)) { latest = page?.latest }
        }
    }

    private func open(_ c: Card) {
        onOpen(c)
        if let route = Route(c) { openRoute(route) }
    }
}

/// Titres trouvés en colonnes de 3, qu'on fait défiler sur le côté ; « Titres › » ouvre la liste complète.
private struct TrackPages: View {
    @Environment(Player.self) private var player
    let tracks: [Track]
    let onOpen: (Card) -> Void

    var body: some View {
        let shown = Array(tracks.prefix(18))
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                AllTracks(tracks: tracks, onOpen: onOpen)
            } label: {
                HStack(spacing: 6) {
                    Text(tr("Titres")).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(52), spacing: 12), count: min(3, shown.count)), spacing: 16) {
                    ForEach(shown.indices, id: \.self) { i in
                        TrackRow(track: shown[i], list: tracks, index: i,
                                 onPlay: { player.remember(.track(shown[i])) },
                                 onOpen: onOpen,
                                 swipeToQueue: false)
                            // Colonne un peu plus étroite que l'écran : la suivante dépasse, on voit qu'on peut glisser.
                            .containerRelativeFrame(.horizontal) { width, _ in width - 56 }
                    }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// Tous les titres trouvés, en liste.
private struct AllTracks: View {
    @Environment(Player.self) private var player
    let tracks: [Track]
    let onOpen: (Card) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(tracks.indices, id: \.self) { i in
                    TrackRow(track: tracks[i], list: tracks, index: i,
                             onPlay: { player.remember(.track(tracks[i])) },
                             onOpen: onOpen)
                }
            }
            .padding(16)
        }
        .navigationTitle(tr("Titres"))
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerSpace()
    }
}

/// Recherches et éléments récents (champ vide), comme sur la version bureau.
private struct HistoryList: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    let search: (String) -> Void

    var body: some View {
        if !player.history.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tr("Récents")).font(.title3.bold())
                    Spacer()
                    Button(tr("Tout effacer")) { withAnimation { player.clearHistory() } }
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.bottom, 6)
                ForEach(player.history, id: \.key) { entry in
                    HStack(spacing: 12) {
                        Button { open(entry) } label: {
                            HStack(spacing: 12) {
                                thumb(entry)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label).lineLimit(1)
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        Button { withAnimation { player.forget(entry) } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func thumb(_ entry: HistoryEntry) -> some View {
        switch entry.kind {
        case .query:
            Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.secondary).frame(width: 44, height: 44)
        case .track:
            CoverView(url: entry.coverUrl, side: 44, radius: 6)
        case .card:
            CoverView(url: entry.card?.coverUrl, side: 44, radius: 6, round: entry.card?.kind == "artist")
        }
    }

    private func open(_ entry: HistoryEntry) {
        switch entry.kind {
        case .query:
            search(entry.query ?? "")
        case .track:
            player.remember(entry)
            player.playHistoryTrack(entry)
        case .card:
            guard let card = entry.card?.card, let route = Route(card) else { return }
            player.remember(entry)
            openRoute(route)
        }
    }
}
