import SwiftUI
import UIKit

/// Position d'une liste de titres gardée quand la page est recréée (recherche dans la liste ouverte ou fermée). Classe
/// simple, que SwiftUI ne surveille pas : la mettre à jour pendant le défilement ne redessine rien.
final class TrackListPosition {
    /// Place (dans la liste lue) du titre en haut de l'écran ; `nil` : haut de la page (en-tête visible).
    var kept: Int?
}

extension EnvironmentValues {
    /// Ligne d'une liste d'iOS (voir `TrackList`) : la confirmation « Retirer des titres aimés » est affichée par la page,
    /// une ligne de ces listes ne pouvant pas l'afficher elle-même. `nil` : le cœur l'affiche lui-même.
    @Entry var askUnlike: ((Track) -> Void)? = nil
}

/// Page faite d'un en-tête puis d'une liste de titres (playlist, album, mix, titres aimés, téléchargements), dans une liste
/// d'iOS comme la file d'attente du lecteur : seules les lignes à l'écran existent, réutilisées en défilant, et la page
/// n'est refaite que si ses titres changent. Avant, une pile SwiftUI : longue à mettre en page dans les grandes playlists,
/// et toutes ses lignes recalculées à chaque mise à jour de la page. Les lignes restent celles de l'app (`TrackRow`).
struct TrackList<Header: View>: View {
    @Environment(Player.self) private var player
    /// Change quand les lignes changent (ordre, recherche, numérotation) : sinon elles ne sont pas refaites. Une autre
    /// liste de titres (page rechargée, titre retiré) est aussi repérée sans lui.
    let key: String
    /// Titres affichés (filtrés par une recherche) et liste lue à l'appui sur l'un d'eux (toute la liste, dans l'ordre).
    let tracks: [Track]
    let list: [Track]
    /// Ordre de l'album : numéro devant chaque titre (de 1 à chaque CD) et CD séparés s'il y en a plusieurs.
    var numbered = false
    /// Recherche tapée : la position de la liste complète n'est pas remplacée par celle des résultats.
    var filtered = false
    /// Texte sous l'en-tête (aucun résultat, liste vide).
    var message: String?
    var likeButton = false
    var hideLiked = false
    var onRemove: ((Track) -> Void)?
    /// Position gardée quand la page est recréée.
    var position: TrackListPosition?
    var onRefresh: (() async -> Void)?
    /// Liste reprise au doigt.
    var onDrag: (() -> Void)?
    @ViewBuilder let header: () -> Header
    @State private var unlike: Track? = nil

    var body: some View {
        // Marges des barres (navigation, onglets, mini-lecteur, clavier) lues ici et données à la liste : elle passe sous les
        // barres, comme les pages SwiftUI, et son contenu commence et finit à la bonne place.
        GeometryReader { geo in
            TrackCollection(page: self, header: AnyView(header()), insets: geo.safeAreaInsets) { unlike = $0 }
                .ignoresSafeArea()
        }
        .confirmationDialog(tr("Retirer « %@ » de « %@ » ?", unlike?.title ?? "", player.lovedTitle),
                            isPresented: Binding(get: { unlike != nil }, set: { if !$0 { unlike = nil } }),
                            titleVisibility: .visible, presenting: unlike) { t in
            Button(tr("Retirer"), role: .destructive) { player.setLiked(t, false) }
        }
    }
}

/// Liste d'iOS qui prévient quand elle arrive dans une fenêtre et à chaque mise en page.
private final class PageCollectionView: UICollectionView {
    var onWindow: (() -> Void)?
    var onLayout: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindow?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Ce que les lignes lisent dans l'environnement de la page : une ligne d'une liste d'iOS ne l'hérite pas, il lui est
/// redonné.
private struct RowEnvironment: ViewModifier {
    let player: Player
    let openRoute: (Route) -> Void
    let pageVisible: Bool
    let glassReacts: Bool
    let phase: ScenePhase
    let askUnlike: (Track) -> Void

    func body(content: Content) -> some View {
        content
            .environment(player)
            .environment(\.openRoute, openRoute)
            .environment(\.pageVisible, pageVisible)
            .environment(\.glassReactsToTouch, glassReacts)
            .environment(\.scenePhase, phase)
            .environment(\.askUnlike, askUnlike)
            // Couleur du thème (barres de téléchargement, boutons) : posée sur l'app, elle n'arrive pas jusqu'ici.
            .tint(Theme.accent)
    }
}

private struct TrackCollection: UIViewRepresentable {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @Environment(\.pageVisible) private var pageVisible
    @Environment(\.glassReactsToTouch) private var glassReacts
    @Environment(\.scenePhase) private var phase
    /// Réglages de la page, lus à chaque mise à jour (un `TrackList` de n'importe quel en-tête).
    let key: String
    let tracks: [Track]
    let list: [Track]
    let numbered: Bool
    let filtered: Bool
    let message: String?
    let likeButton: Bool
    let hideLiked: Bool
    let onRemove: ((Track) -> Void)?
    /// Position gardée (nommée autrement que le modificateur `position` de SwiftUI, que Swift prenait à sa place).
    let memory: TrackListPosition?
    let onRefresh: (() async -> Void)?
    let onDrag: (() -> Void)?
    let header: AnyView
    let insets: EdgeInsets
    let askUnlike: (Track) -> Void

    init<H: View>(page: TrackList<H>, header: AnyView, insets: EdgeInsets, askUnlike: @escaping (Track) -> Void) {
        key = page.key
        tracks = page.tracks
        list = page.list
        numbered = page.numbered
        filtered = page.filtered
        message = page.message
        likeButton = page.likeButton
        hideLiked = page.hideLiked
        onRemove = page.onRemove
        memory = page.position
        onRefresh = page.onRefresh
        onDrag = page.onDrag
        self.header = header
        self.insets = insets
        self.askUnlike = askUnlike
    }

    /// Lu pendant la mise à jour de la vue seulement (plus tard, l'environnement n'est plus valable) : gardé par la liste.
    var environment: RowEnvironment {
        RowEnvironment(player: player, openRoute: openRoute, pageVisible: pageVisible, glassReacts: glassReacts, phase: phase,
                       askUnlike: askUnlike)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeView(self) }

    func updateUIView(_ view: UICollectionView, context: Context) { context.coordinator.update(self) }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        /// `disc` : numéro du CD et place de son en-tête (un même CD revenu plus loin ne fait pas deux fois le même
        /// identifiant, ce que la liste d'iOS refuse).
        enum Item: Hashable { case header, message, disc(UInt32, Int), track(String) }

        /// Une ligne : le titre, sa place dans la liste lue et son numéro d'album.
        private struct Row {
            let track: Track
            let index: Int
            let number: Int?
        }

        private var page: TrackCollection!
        private weak var view: PageCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
        private var rows: [String: Row] = [:]
        /// Place dans la liste lue → ligne (pour remettre la liste à sa position).
        private var rowAt: [Int: String] = [:]
        private var trackItems: [String] = []
        /// Ce qui a servi à faire les lignes affichées.
        private var key: String?
        private var tracks: [Track] = []
        private var list: [Track] = []
        private var filtered = false
        /// Ligne à amener en haut dès que la liste a sa taille.
        private var pendingTop: String?
        /// Environnement de la page, lu à la dernière mise à jour.
        private var env: RowEnvironment!
        private var envKey = ""

        func makeView(_ page: TrackCollection) -> UICollectionView {
            self.page = page
            env = page.environment
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let view = PageCollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
            view.backgroundColor = .clear
            // Marges des barres posées à la main (voir `TrackList`) : celles d'iOS s'y ajouteraient.
            view.contentInsetAdjustmentBehavior = .never
            view.keyboardDismissMode = .interactive
            view.alwaysBounceVertical = true
            view.delegate = self
            view.onWindow = { [weak self] in self?.adoptBars() }
            view.onLayout = { [weak self] in self?.laidOut() }
            self.view = view

            let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
                self?.configure(cell, item)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, path, item in
                view.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
            }
            if page.onRefresh != nil {
                let refresh = UIRefreshControl()
                refresh.addAction(UIAction { [weak self, weak refresh] _ in
                    Task { @MainActor in
                        await self?.page.onRefresh?()
                        refresh?.endRefreshing()
                    }
                }, for: .valueChanged)
                view.refreshControl = refresh
            }
            return view
        }

        func update(_ page: TrackCollection) {
            self.page = page
            env = page.environment
            applyInsets(page.insets)
            let envNow = "\(env.pageVisible)|\(env.glassReacts)|\(env.phase)|\(page.likeButton)|\(page.hideLiked)"
            if key != page.key || !Self.same(page.tracks, tracks) || !Self.same(page.list, list) {
                envKey = envNow
                rebuild()
            } else {
                // En-tête refait avec l'état de la page (il en dépend : page rechargée, tri, boutons).
                if let path = dataSource.indexPath(for: .header), let cell = view?.cellForItem(at: path) as? UICollectionViewListCell {
                    configure(cell, .header)
                }
                if envNow != envKey {
                    envKey = envNow
                    reconfigureVisible()
                }
            }
        }

        /// Même liste : même mémoire. Les listes de la page sont gardées telles quelles tant qu'elles ne changent pas (voir
        /// `SortedTracks`) : bien plus rapide que de comparer des milliers de titres à chaque mise à jour.
        private static func same(_ a: [Track], _ b: [Track]) -> Bool {
            a.count == b.count && a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress } }
        }

        private func rebuild() {
            let wasFiltered = filtered
            let first = key == nil
            let before = trackItems
            key = page.key
            tracks = page.tracks
            list = page.list
            filtered = page.filtered

            // Place de chaque titre affiché dans la liste lue (seulement pendant une recherche, sinon la même).
            let position: [Int64: Int] = tracks.count == list.count ? [:]
                : Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { earliest, _ in earliest })
            // CD inconnu pour certains titres (copie hors ligne en partie téléchargée avant que l'app note les CD) : ni
            // « CD 0 » ni numéros mélangés, une seule numérotation.
            let disks = Set(tracks.map(\.disk))
            let discs = page.numbered && disks.count > 1 && !disks.contains(0)
            var counts: [UInt32: Int] = [:]
            var seen: [Int64: Int] = [:]
            var items: [Item] = [.header]
            if page.message != nil { items.append(.message) }
            rows = [:]
            rowAt = [:]
            trackItems = []
            for (i, t) in tracks.enumerated() {
                if discs, i == 0 || tracks[i - 1].disk != t.disk { items.append(.disc(t.disk, i)) }
                // Un même titre peut être deux fois dans une playlist : identité « titre + nième apparition ».
                let nth = seen[t.id, default: 0]
                seen[t.id] = nth + 1
                let id = "\(t.id)-\(nth)"
                var number: Int?
                if page.numbered {
                    let disk = discs ? t.disk : 0
                    counts[disk, default: 0] += 1
                    number = counts[disk]
                }
                let index = position[t.id] ?? i
                rows[id] = Row(track: t, index: index, number: number)
                if rowAt[index] == nil { rowAt[index] = id }
                trackItems.append(id)
                items.append(.track(id))
            }

            var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
            snapshot.appendSections([0])
            snapshot.appendItems(items)
            // Lignes déjà là : refaites avec leurs nouvelles données (numéro, place, titre mis à jour).
            snapshot.reconfigureItems(items.filter { dataSource.indexPath(for: $0) != nil })
            // Un titre retiré (de la playlist, ou du téléphone) : il s'efface en douceur. Tout autre changement (tri,
            // recherche, page rechargée) : la liste est remplacée d'un coup, sans animer des milliers de lignes.
            let removal = !first && !wasFiltered && !filtered && trackItems.count == before.count - 1
                && Set(trackItems).isSubset(of: Set(before))
            dataSource.apply(snapshot, animatingDifferences: removal)

            // Liste complète affichée (ouverture de la page, ou recherche effacée) : remise à sa position d'avant.
            if !filtered, first || wasFiltered, let kept = page.memory?.kept, let id = rowAt[kept] {
                pendingTop = id
                view?.setNeedsLayout()
            } else if filtered != wasFiltered, let view {
                // Résultats d'une recherche : en haut.
                view.setContentOffset(CGPoint(x: 0, y: -view.contentInset.top), animated: false)
            }
        }

        private func reconfigureVisible() {
            guard let view else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(view.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
            cell.backgroundConfiguration = .clear()
            let env = env!
            switch item {
            case .header:
                let header = page.header
                cell.contentConfiguration = UIHostingConfiguration { header.modifier(env) }.margins(.all, 0)
            case .message:
                let text = page.message ?? ""
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }.margins(.horizontal, 16).margins(.vertical, 7)
            case .disc(let disk, let at):
                let top: CGFloat = at == 0 ? 0 : 14
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(tr("CD %@", "\(disk)")).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, top)
                }.margins(.horizontal, 16).margins(.vertical, 7)
            case .track(let id):
                guard let row = rows[id] else { return }
                let list = list
                let remove = page.onRemove.map { remove in { remove(row.track) } }
                let likeButton = page.likeButton, hideLiked = page.hideLiked
                cell.contentConfiguration = UIHostingConfiguration {
                    TrackRow(track: row.track, list: list, index: row.index, number: row.number, likeButton: likeButton,
                             hideLiked: hideLiked, onRemove: remove)
                        // État de la ligne (glissement, suivi du téléchargement) propre à ce titre : une case réutilisée
                        // pour un autre titre repart de zéro.
                        .id(id)
                        .modifier(env)
                }.margins(.horizontal, 16).margins(.vertical, 7)
            }
        }

        private func applyInsets(_ insets: EdgeInsets) {
            guard let view else { return }
            // Bas : 12 points sous la dernière ligne (5 avec sa propre marge), comme avant.
            let atTop = view.contentOffset.y <= -view.contentInset.top + 0.5
            // Haut : suivi seulement en haut de la liste (champ de recherche qui apparaît…). Plus bas, la barre d'un grand
            // titre se replie en défilant et sa hauteur change : la marge refaite à chaque image ferait sauter la liste.
            let top = atTop || view.contentInset.top == 0 ? insets.top : view.contentInset.top
            let new = UIEdgeInsets(top: top, left: 0, bottom: insets.bottom + 5, right: 0)
            guard view.contentInset != new else { return }
            view.contentInset = new
            view.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: insets.bottom, right: 0)
            // En haut de la page (ouverture, champ de recherche qui apparaît) : le haut reste visible sous la barre.
            if atTop { view.contentOffset.y = -new.top }
        }

        /// La page déclare cette liste comme la sienne : la barre du haut et celle des onglets réagissent à son défilement,
        /// comme avec les pages SwiftUI.
        private func adoptBars() {
            guard let view else { return }
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    controller.setContentScrollView(view, for: .top)
                    controller.setContentScrollView(view, for: .bottom)
                    return
                }
                responder = next
            }
        }

        private func laidOut() {
            guard let id = pendingTop, let view, view.bounds.height > 0 else { return }
            pendingTop = nil
            // Hors de la mise en page en cours ; deux fois : les lignes autour ne sont mesurées qu'une fois affichées.
            DispatchQueue.main.async { [weak self] in
                self?.scroll(to: id)
                DispatchQueue.main.async { self?.scroll(to: id) }
            }
        }

        private func scroll(to id: String) {
            guard let view, let path = dataSource.indexPath(for: .track(id)) else { return }
            view.scrollToItem(at: path, at: .top, animated: false)
            view.layoutIfNeeded()
            guard let frame = view.layoutAttributesForItem(at: path)?.frame else { return }
            let bottom = max(-view.contentInset.top, view.contentSize.height + view.contentInset.bottom - view.bounds.height)
            view.contentOffset.y = min(frame.minY - view.contentInset.top, bottom)
        }

        // MARK: Défilement

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { page.onDrag?() }

        /// Titre en haut de l'écran, gardé pendant que l'utilisateur fait défiler la liste complète (voir `TrackListPosition`).
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !filtered, scrollView.isTracking || scrollView.isDecelerating, let memory = page.memory,
                  let view else { return }
            let point = CGPoint(x: view.bounds.midX, y: view.contentOffset.y + view.contentInset.top + 1)
            guard let path = view.indexPathForItem(at: point), let item = dataSource.itemIdentifier(for: path) else { return }
            switch item {
            case .header: memory.kept = nil
            case .track(let id): memory.kept = rows[id]?.index
            case .message, .disc: break
            }
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { page.memory?.kept = nil }

        // Les lignes gèrent leurs appuis elles-mêmes (boutons SwiftUI) : la liste ne sélectionne ni ne surligne rien.
        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt path: IndexPath) -> Bool { false }
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt path: IndexPath) -> Bool { false }
    }
}
