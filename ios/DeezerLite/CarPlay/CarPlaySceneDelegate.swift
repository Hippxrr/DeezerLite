import CarPlay
import Observation
import UIKit

/// Écran CarPlay : Accueil, Bibliothèque et Récents organisés selon les réglages de l'app, et l'écran « À l'écoute ».
/// Tout passe par `Player.shared` : la lecture lancée depuis la voiture est la même que dans l'app.
/// Les listes se redessinent d'elles-mêmes quand les données du lecteur changent (suivi Observation).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    private let player = Player.shared
    private let nowPlaying = CPNowPlayingTemplate.shared

    // MARK: Connexion

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated { connect(interfaceController) }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                              didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            nowPlaying.remove(self)
            interface = nil // les suivis s'arrêtent d'eux-mêmes à leur prochain réveil
        }
    }

    private func connect(_ interfaceController: CPInterfaceController) {
        interface = interfaceController

        let home = CPListTemplate(title: tr("Accueil"), sections: [])
        home.tabTitle = tr("Accueil")
        home.tabImage = UIImage(systemName: "house.fill")
        let library = CPListTemplate(title: tr("Bibliothèque"), sections: [])
        library.tabTitle = tr("Bibliothèque")
        library.tabImage = UIImage(systemName: "music.note.list")
        let recent = CPListTemplate(title: tr("Récents"), sections: [])
        recent.tabTitle = tr("Récents")
        recent.tabImage = UIImage(systemName: "clock.fill")
        recent.emptyViewTitleVariants = [tr("Aucun titre récent")]

        observe(while: home) { [weak self] in self?.fillHome(home) }
        observe(while: library) { [weak self] in self?.fillLibrary(library) }
        observe(while: recent) { [weak self] in self?.fillRecent(recent) }

        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = tr("À suivre")
        nowPlaying.add(self)
        observe(while: nil) { [weak self] in self?.fillNowPlayingButtons() }

        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [home, library, recent]), animated: false, completion: nil)

        player.retrySessionFromCarPlay()
        Task {
            await player.loadHome(force: false)
            await player.loadLibrary(0, force: false)
        }
    }

    // MARK: Suivi des données

    /// Exécute `body` et le relance à chaque changement des valeurs du lecteur qu'il a lues,
    /// tant que CarPlay est connecté et que `template` (s'il y en a un) est encore affiché.
    private func observe(while template: CPTemplate?, _ body: @escaping () -> Void) {
        withObservationTracking(body, onChange: {
            Task { @MainActor [weak self, weak template] in
                guard let self, let interface = self.interface else { return }
                if let template, !self.isShown(template, in: interface) { return }
                self.observe(while: template, body)
            }
        })
    }

    private func isShown(_ template: CPTemplate, in interface: CPInterfaceController) -> Bool {
        if interface.templates.contains(where: { $0 === template }) { return true }
        // Onglets : enfants du modèle racine.
        if let tabs = interface.rootTemplate as? CPTabBarTemplate { return tabs.templates.contains { $0 === template } }
        return false
    }

    // MARK: Accueil

    private func fillHome(_ template: CPListTemplate) {
        guard player.loggedIn == true else {
            template.updateSections([CPListSection(items: [notice(player.loggedIn == nil ? tr("Connexion à Deezer…") : tr("Connecte-toi dans l'app sur ton iPhone"))])])
            return
        }
        var sections: [CPListSection] = []
        // Haut de l'accueil comme dans l'app : Flow et Titres aimés s'ils y sont affichés, épinglés, dans l'ordre choisi.
        let top: [CPListItem] = player.homeItems.compactMap { item -> CPListItem? in
            switch item {
            case .flow: return flowItem()
            case .loved: return lovedItem()
            case .pin(let pin): return cardItem(pin.card)
            }
        }
        if !top.isEmpty { sections.append(CPListSection(items: top)) }
        // Recommandations : seulement si elles sont activées, avec les catégories et l'ordre réglés dans l'app.
        if player.reco.anyVisible {
            for shelf in player.reco.shelves(player.home ?? []) {
                let items = shelf.items.compactMap(cardItem)
                if !items.isEmpty { sections.append(CPListSection(items: items, header: shelf.title, sectionIndexTitle: nil)) }
            }
        }
        template.emptyViewTitleVariants = [tr("Rien sur l'accueil")]
        template.updateSections(limit(sections))
    }

    private func flowItem() -> CPListItem {
        let flow = CPListItem(text: "Flow", detailText: tr("Ta musique, en continu"), image: UIImage(systemName: "waveform"))
        setCover(flow, player.flowCover)
        flow.isPlaying = player.isFlow && player.current != nil
        flow.handler = { [weak self] _, done in
            MainActor.assumeIsolated {
                self?.player.playFlow()
                self?.showNowPlaying()
            }
            done()
        }
        return flow
    }

    private func lovedItem() -> CPListItem {
        let count = player.lovedIds.count
        let loved = CPListItem(text: player.lovedTitle, detailText: count > 0 ? tr("%@ titres", "\(count)") : nil, image: UIImage(systemName: "heart.fill"))
        setCover(loved, player.lovedCover)
        loved.accessoryType = .disclosureIndicator
        loved.handler = { [weak self] _, done in
            MainActor.assumeIsolated { self?.openDetail(.loved, title: self?.player.lovedTitle ?? "") }
            done()
        }
        return loved
    }

    // MARK: Bibliothèque

    private func fillLibrary(_ template: CPListTemplate) {
        guard player.loggedIn == true else {
            template.updateSections([CPListSection(items: [notice(tr("Connecte-toi dans l'app sur ton iPhone"))])])
            return
        }
        // Flow et Titres aimés retirés de l'accueil : ils sont ici, en tête, comme dans l'app.
        var top: [CPListItem] = []
        if !player.flowOnHome { top.append(flowItem()) }
        if !player.lovedOnHome { top.append(lovedItem()) }
        let tabs: [(String, String, Int)] = [(tr("Playlists"), "music.note.list", 0), (tr("Albums"), "square.stack", 1), (tr("Artistes"), "music.mic", 2)]
        let lists = tabs.map { title, symbol, tab in
            let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in
                MainActor.assumeIsolated { self?.openLibrary(tab, title: title) }
                done()
            }
            return item
        }
        template.updateSections([CPListSection(items: top + lists)])
    }

    private func openLibrary(_ tab: Int, title: String) {
        player.retrySessionFromCarPlay()
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = [tr("Chargement…")]
        observe(while: template) { [weak self] in
            guard let self else { return }
            // Comme dans l'app : sans Titres aimés (à part) ni les éléments épinglés (sur l'accueil).
            let cards = (player.library[tab] ?? []).filter { $0.kind != "loved" && !self.player.isPinned($0) }
            if player.library[tab] != nil { template.emptyViewTitleVariants = [tr("Rien ici pour l'instant")] }
            template.updateSections(limit([CPListSection(items: cards.compactMap(cardItem))]))
        }
        push(template)
        Task { await player.loadLibrary(tab, force: false) }
    }

    // MARK: Récents

    private func fillRecent(_ template: CPListTemplate) {
        let currentId = player.current?.id
        let items: [CPListItem] = player.history.compactMap { entry in
            switch entry.kind {
            case .track:
                guard let id = entry.trackId else { return nil }
                let item = CPListItem(text: entry.title ?? "", detailText: entry.subtitle, image: placeholder)
                setCover(item, entry.coverUrl)
                item.isPlaying = id == currentId
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated {
                        self?.player.playHistoryTrack(entry)
                        self?.showNowPlaying()
                    }
                    done()
                }
                return item
            case .card:
                return entry.card.flatMap { cardItem($0.card) }
            case .query:
                return nil
            }
        }
        template.updateSections(limit([CPListSection(items: items)]))
    }

    // MARK: Pages (playlist, album, artiste, mix, coups de cœur)

    private func cardItem(_ card: Card) -> CPListItem? {
        guard let route = Route(card) else { return nil }
        let title = card.kind == "loved" ? player.lovedTitle : card.title
        let item = CPListItem(text: title, detailText: card.subtitle.isEmpty ? nil : card.subtitle, image: placeholder)
        setCover(item, player.coverURL(card))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, done in
            MainActor.assumeIsolated { self?.openDetail(route, title: title) }
            done()
        }
        return item
    }

    private func openDetail(_ route: Route, title: String) {
        player.retrySessionFromCarPlay()
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = [tr("Chargement…")]
        push(template)
        Task {
            guard let detail = await player.detail(route, force: false) else {
                template.emptyViewTitleVariants = [tr("Impossible de charger cette page")]
                template.updateSections([])
                return
            }
            template.emptyViewTitleVariants = [tr("Aucun titre")]
            // Redessinée quand le titre en cours change (indicateur de lecture).
            observe(while: template) { [weak self] in self?.fillDetail(template, detail) }
        }
    }

    private func fillDetail(_ template: CPListTemplate, _ detail: Detail) {
        var sections: [CPListSection] = []
        // La voiture n'affiche que les premières lignes, mais c'est toute la page qui part en lecture.
        let all = detail.tracks
        let tracks = Array(all.prefix(maxItems - 1))
        if !tracks.isEmpty {
            let shuffle = CPListItem(text: tr("Lecture aléatoire"), detailText: nil, image: UIImage(systemName: "shuffle"))
            shuffle.handler = { [weak self] _, done in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.player.shuffle { self.player.toggleShuffle() }
                    self.player.play(all, at: Int.random(in: 0..<all.count))
                    self.showNowPlaying()
                }
                done()
            }
            let currentId = player.current?.id
            let rows = tracks.enumerated().map { index, track in
                let item = CPListItem(text: track.title, detailText: track.artist, image: placeholder)
                setCover(item, track.coverUrl)
                item.isPlaying = track.id == currentId
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated {
                        self?.player.play(all, at: index)
                        self?.showNowPlaying()
                    }
                    done()
                }
                return item
            }
            sections.append(CPListSection(items: [shuffle] + rows))
        }
        // Page artiste : sa discographie sous ses titres.
        let albums = detail.albums.compactMap(cardItem)
        if !albums.isEmpty { sections.append(CPListSection(items: albums, header: tr("Albums"), sectionIndexTitle: nil)) }
        template.updateSections(limit(sections))
    }

    // MARK: À l'écoute

    private func showNowPlaying() {
        guard let interface, interface.topTemplate !== nowPlaying else { return }
        interface.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    /// Aléatoire, répétition et coup de cœur sous les commandes de lecture.
    private func fillNowPlayingButtons() {
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            MainActor.assumeIsolated { self?.player.toggleShuffle() }
        }
        shuffle.isSelected = player.shuffle
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            MainActor.assumeIsolated { self?.player.cycleRepeat() }
        }
        repeatButton.isSelected = player.repeatMode != .off
        var buttons: [CPNowPlayingButton] = [shuffle, repeatButton]
        if let track = player.current {
            let liked = player.lovedIds.contains(track.id)
            if let heart = UIImage(systemName: liked ? "heart.fill" : "heart") {
                buttons.append(CPNowPlayingImageButton(image: heart) { [weak self] _ in
                    MainActor.assumeIsolated { self?.player.setLiked(track, !liked) }
                })
            }
        }
        nowPlaying.updateNowPlayingButtons(buttons)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { openQueue() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    private func openQueue() {
        let template = CPListTemplate(title: tr("À suivre"), sections: [])
        template.emptyViewTitleVariants = [tr("File d'attente vide")]
        observe(while: template) { [weak self] in
            guard let self else { return }
            let current = player.shownIndex
            // Le titre en cours et la suite (pas les titres déjà passés).
            let upcoming = player.queue.enumerated().dropFirst(current).prefix(maxItems)
            let items = upcoming.map { index, track in
                let item = CPListItem(text: track.title, detailText: track.artist, image: self.placeholder)
                self.setCover(item, track.coverUrl)
                item.isPlaying = index == current
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated {
                        self?.player.queuePlay(index)
                        self?.interface?.popTemplate(animated: true, completion: nil)
                    }
                    done()
                }
                return item
            }
            template.updateSections([CPListSection(items: Array(items))])
        }
        push(template)
    }

    // MARK: Outils

    private func push(_ template: CPTemplate) {
        interface?.pushTemplate(template, animated: true, completion: nil)
    }

    private func notice(_ text: String) -> CPListItem {
        CPListItem(text: text, detailText: nil)
    }

    private var placeholder: UIImage? { UIImage(systemName: "music.note") }

    /// La voiture fixe un nombre maximal de lignes (souvent réduit en roulant) : on coupe au-delà.
    private var maxItems: Int { max(1, Int(CPListTemplate.maximumItemCount)) }

    private func limit(_ sections: [CPListSection]) -> [CPListSection] {
        var left = maxItems
        var result: [CPListSection] = []
        for section in sections.prefix(Int(CPListTemplate.maximumSectionCount)) where left > 0 {
            let items = Array(section.items.prefix(left))
            left -= items.count
            result.append(CPListSection(items: items, header: section.header, sectionIndexTitle: nil))
        }
        return result
    }

    /// Pochette de la ligne : tout de suite si elle est en mémoire, sinon chargée puis posée.
    private func setCover(_ item: CPListItem, _ url: String?) {
        guard let url else { return }
        let pixels = Int(CPListItem.maximumImageSize.width * 3)
        if let hit = CoverLoader.shared.cached(url: url, pixels: pixels) {
            item.setImage(hit)
            return
        }
        Task {
            if let image = await CoverLoader.shared.image(url: url, pixels: pixels) { item.setImage(image) }
        }
    }
}
