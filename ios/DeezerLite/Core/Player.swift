import AVFoundation
import Foundation
import Network
import Observation
import UIKit

/// Reçoit les événements du cœur sur un thread Rust et les renvoie au thread principal, dans l'ordre d'arrivée.
/// (Des `Task` séparées ne garantissent pas cet ordre : un vieil état « en pause, 0:00 » pouvait passer après le bon
/// et rester affiché sur l'écran verrouillé.)
final class CoreEvents: Listener, @unchecked Sendable {
    weak var player: Player?

    func onEvent(event: Event) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.player?.handle(event) }
        }
    }
}

/// État observé par une seule ligne de titre : la progression d'un téléchargement ne touche pas les autres lignes.
@Observable
final class TrackDownloadStatus {
    var update: DownloadUpdate?
    var downloaded = false
    /// Titre suivi. Une ligne réutilisée pour un autre titre (listes affichées par position) change de titre :
    /// tant que l'état n'a pas suivi, la ligne lit celui du lecteur (voir `TrackRow`).
    var id: Int64?
}

private final class WeakTrackDownloadStatus {
    weak var value: TrackDownloadStatus?

    init(_ value: TrackDownloadStatus) {
        self.value = value
    }
}

/// Seul point de contact entre SwiftUI et le cœur Rust.
/// `@Observable` : une vue n'est redessinée que si une propriété qu'elle lit change
/// (une pause ne redessine plus les listes de titres, seulement le bouton et l'indicateur).
@MainActor
@Observable
final class Player {
    static let shared = Player()

    let core: Core?
    private let events = CoreEvents()

    /// `nil` tant que la session n'a pas été vérifiée au lancement.
    private(set) var loggedIn: Bool?
    private(set) var current: Track?
    private(set) var status = Status(playing: false, positionMs: 0, durationMs: 0)
    /// Instant où `status` a été reçu : la position affichée est extrapolée à partir de là, sans interroger Rust.
    private(set) var statusAt = Date()
    /// Titre demandé, son pas encore arrivé (affiché tout de suite pour que l'appui réponde immédiatement).
    private(set) var loading = false
    private(set) var queue: [Track] = []
    private(set) var queueIndex = 0
    private(set) var shuffle = false
    private(set) var repeatMode: Repeat = .off
    /// Identifiants des titres aimés (pas les fiches : elles restent dans Rust).
    private(set) var lovedIds: Set<Int64> = []
    var showFullPlayer = false
    /// Titre affiché dans la file : pendant une rafale de suivant / précédent il devance le cœur
    /// (sert aux pochettes voisines du lecteur plein écran).
    private(set) var shownIndex = 0
    /// Page demandée hors d'un onglet (depuis le lecteur plein écran) : l'onglet actif l'ouvre.
    var requestedRoute: Route?
    /// Pages déjà chargées : affichées tout de suite en revenant dessus (tirer vers le bas pour actualiser).
    private(set) var home: [Shelf]?
    private(set) var library: [Int: [Card]] = [:]
    @ObservationIgnored private var details: [Route: Detail] = [:]
    @ObservationIgnored private var detailOrder: [Route] = []
    private let maxDetails = 12
    var message: String?
    /// Qualité audio en Wi-Fi et en données mobiles (Réglages, gardées sur le téléphone).
    private(set) var quality: AudioQuality = Player.savedQuality("quality")
    private(set) var cellularQuality: AudioQuality = Player.savedQuality("cellularQuality")
    private(set) var downloadQuality: AudioQuality = Player.savedQuality("downloadQuality")
    private(set) var downloads: [Track] = []
    private(set) var downloadCollections: [DownloadCollection] = []
    private(set) var downloadedIds: Set<Int64> = []
    private(set) var downloadStates: [Int64: DownloadUpdate] = [:]
    private(set) var downloadTracks: [Int64: Track] = [:]
    private(set) var downloadBytes: UInt64 = 0
    /// Plusieurs lignes peuvent afficher le même titre (page + file, doublon dans une playlist) : toutes sont suivies.
    @ObservationIgnored private var downloadRows: [Int64: [WeakTrackDownloadStatus]] = [:]
    @ObservationIgnored private var downloadsRefreshTask: Task<Void, Never>?
    /// Changé à chaque mise à jour immédiate des listes : un rafraîchissement en arrière-plan commencé avant ne les
    /// écrase pas avec un état plus ancien (titre supprimé entre-temps, déconnexion).
    @ObservationIgnored private var downloadsVersion = 0
    @ObservationIgnored private var bytesTask: Task<Void, Never>?
    /// Réseau du moment : données mobiles (4G / 5G) ou non.
    private(set) var onCellular = false
    /// Qualité réellement demandée au cœur (pour ne recharger le titre que si elle change).
    @ObservationIgnored private var appliedQuality: AudioQuality = .flac
    private let network = NWPathMonitor()

    private static func savedQuality(_ key: String) -> AudioQuality {
        switch UserDefaults.standard.string(forKey: key) {
        case "mp3High": .mp3High
        case "mp3Low": .mp3Low
        default: .flac
        }
    }

    private static func raw(_ q: AudioQuality) -> String {
        switch q { case .flac: "flac"; case .mp3High: "mp3High"; case .mp3Low: "mp3Low" }
    }

    /// Les titres aimés sont téléchargés sous l'identifiant 0 (page Titres aimés), alors que leur carte sur l'accueil et
    /// dans la bibliothèque porte l'identifiant de la playlist « Coups de cœur » : on ramène tout à 0.
    private static func downloadId(kind: String, id: UInt64) -> UInt64 {
        kind == "loved" ? 0 : id
    }

    /// Qualité qui convient au réseau du moment. `reload` : choix fait dans les réglages, le titre en cours est rechargé
    /// tout de suite (à la même position). Changement de réseau : la qualité vaut à partir du titre suivant, sans
    /// retélécharger celui en cours.
    private func applyQuality(reload: Bool = false) {
        let wanted = onCellular ? cellularQuality : quality
        guard wanted != appliedQuality else { return }
        appliedQuality = wanted
        attempt { try $0.setQuality(quality: wanted, reload: reload) }
    }

    /// Passage Wi-Fi <-> 4G/5G : la qualité suit le réseau. Les connexions restées sur l'ancien réseau sont repérées
    /// par le cœur (ping HTTP/2) et le téléchargement reprend là où il s'était arrêté.
    private func watchNetwork() {
        network.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let cellular = up && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            // Signature du réseau : elle change au passage Wi-Fi <-> données mobiles, et au retour du réseau.
            let signature = up ? (path.usesInterfaceType(.wifi) ? "wifi" : cellular ? "cellular" : "other") : "none"
            // Dans l'ordre d'arrivée (des tâches séparées pouvaient s'exécuter dans le désordre : Wi-Fi → rien → 4G).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(signature: signature, cellular: cellular) } }
        }
        network.start(queue: DispatchQueue(label: "dz.network", qos: .utility))
    }

    @ObservationIgnored private var networkSignature: String?
    @ObservationIgnored private var restoringSession = false

    private func networkChanged(signature: String, cellular: Bool) {
        defer { networkSignature = signature }
        // Sans réseau, les téléchargements attendent au lieu d'échouer ; ils repartent à son retour.
        BackgroundDownloadManager.shared.networkChanged(up: signature != "none")
        // Premier relevé au lancement : rien à réinitialiser.
        guard let previous = networkSignature, previous != signature else {
            if onCellular != cellular { onCellular = cellular; applyQuality() }
            return
        }
        // Les requêtes suivantes (titre suivant, pages…) partent sur des connexions du nouveau réseau,
        // sans attendre qu'une connexion de l'ancien expire.
        if signature != "none" {
            core?.networkChanged()
            // Profils pas lus (coupure juste après la connexion) : relus maintenant.
            if sessionReady, profiles.isEmpty { Task { await loadProfiles() } }
            // Pages ouvertes pendant la coupure (copies hors ligne) : rechargées depuis Deezer à la prochaine visite.
            if sessionReady { forgetOfflineDetails() }
            // Lancé sans réseau : la session Deezer est ouverte maintenant que le réseau est revenu.
            if loggedIn == true, !sessionReady {
                Task { await restore() }
            }
        }
        if onCellular != cellular {
            onCellular = cellular
            applyQuality()
        }
    }

    func setQuality(_ q: AudioQuality) {
        quality = q
        UserDefaults.standard.set(Player.raw(q), forKey: "quality")
        applyQuality(reload: true)
    }

    func setCellularQuality(_ q: AudioQuality) {
        cellularQuality = q
        UserDefaults.standard.set(Player.raw(q), forKey: "cellularQuality")
        applyQuality(reload: true)
    }

    func setDownloadQuality(_ q: AudioQuality) {
        downloadQuality = q
        UserDefaults.standard.set(Player.raw(q), forKey: "downloadQuality")
        core?.setDownloadQuality(quality: q)
    }

    func download(_ detail: Detail) {
        guard core != nil, !detail.tracks.isEmpty else { return }
        Task {
            do {
                let missing = try await storeDownloadCollection(detail)
                if missing.isEmpty {
                    showToast("\(detail.title) est disponible hors ligne")
                } else {
                    download(missing)
                }
            } catch { message = describe(error) }
        }
    }

    private func storeDownloadCollection(_ detail: Detail) async throws -> [Track] {
        guard let core else { return [] }
        try await core.downloadCollection(detail: detail)
        refreshDownloads()
        return detail.tracks.filter { !downloadedIds.contains($0.id) }
    }

    private func syncDownloadedCollection(kind: String, id: UInt64) async -> Bool {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return false }
        let gen = profileGeneration
        do {
            let fresh = kind == "loved"
                ? try await core.lovedDetail()
                : try await core.openDetail(kind: kind, id: id)
            // Deezer injoignable : le cœur a renvoyé la copie hors ligne, qu'il ne faut pas réenregistrer
            // (les titres pas encore téléchargés disparaîtraient de la collection).
            guard !fresh.offline else { return false }
            // Profil changé pendant la requête : la réponse peut être celle de l'autre profil.
            guard gen == profileGeneration else { return false }
            // La collection a pu être retirée des téléchargements pendant la requête.
            guard downloadedCollection(kind: kind, id: id) != nil else { return true }
            let missing = try await storeDownloadCollection(fresh)
            let new = missing.filter { downloadStates[$0.id] == nil }
            if !new.isEmpty { download(new) }
            return true
        } catch {
            return false
        }
    }

    /// Une collection qui échoue (playlist supprimée sur Deezer…) n'empêche plus la synchro des suivantes.
    private func syncDownloadedCollections() async {
        let saved = downloadCollections
        for collection in saved {
            _ = await syncDownloadedCollection(kind: collection.kind, id: collection.id)
        }
    }

    /// Ajoute un titre à une collection téléchargée et lance son téléchargement, sans recharger toute la collection.
    private func addDownloadedTrack(kind: String, id: UInt64, track: Track) {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return }
        do {
            _ = try core.addDownloadTrackToCollection(kind: kind, id: Self.downloadId(kind: kind, id: id), trackId: track.id)
            refreshDownloads()
            if !downloadedIds.contains(track.id), downloadStates[track.id] == nil { download([track]) }
        } catch {
            showToast("La copie hors ligne n'a pas pu être actualisée", seconds: 4)
        }
    }

    private func removeDownloadedTrack(kind: String, id: UInt64, trackId: Int64) {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return }
        do {
            _ = try core.removeDownloadTrackFromCollection(kind: kind, id: Self.downloadId(kind: kind, id: id), trackId: trackId)
            refreshDownloads()
        } catch {
            showToast("La copie hors ligne n'a pas pu être actualisée", seconds: 4)
        }
    }

    func downloadedCollection(kind: String, id: UInt64) -> DownloadCollection? {
        let id = Self.downloadId(kind: kind, id: id)
        return downloadCollections.first { $0.kind == kind && $0.id == id }
    }

    func toggleDownload(_ detail: Detail) {
        if let collection = downloadedCollection(kind: detail.kind, id: detail.id) {
            removeDownloadCollection(collection)
        } else {
            download(detail)
        }
    }

    /// Collections dont la liste des titres est en train d'arriver de Deezer (« Télécharger la playlist » depuis une carte).
    private(set) var preparingDownloads: Set<String> = []

    private static func preparingKey(kind: String, id: UInt64) -> String {
        "\(kind):\(downloadId(kind: kind, id: id))"
    }

    func isPreparingDownload(_ card: Card) -> Bool {
        preparingDownloads.contains(Self.preparingKey(kind: card.kind, id: card.id))
    }

    func toggleDownload(_ card: Card) {
        if let collection = downloadedCollection(kind: card.kind, id: card.id) {
            removeDownloadCollection(collection)
            return
        }
        let key = Self.preparingKey(kind: card.kind, id: card.id)
        // Déjà demandé : un second appui pendant la préparation ne relance rien.
        guard let route = Route(card), !preparingDownloads.contains(key) else { return }
        preparingDownloads.insert(key)
        // Réponse immédiate à l'appui : la liste des titres peut mettre une ou deux secondes à arriver.
        showToast("Préparation du téléchargement…", seconds: 10)
        Task {
            defer { preparingDownloads.remove(key) }
            if let detail = await detail(route, force: false), !detail.offline {
                download(detail)
            } else {
                showToast("Impossible de charger cette collection", seconds: 4)
            }
        }
    }

    func download(_ tracks: [Track]) {
        guard core != nil, !tracks.isEmpty else { return }
        let accepted = BackgroundDownloadManager.shared.enqueue(tracks.filter { !downloadedIds.contains($0.id) })
        var nextTracks = downloadTracks
        var nextStates = downloadStates
        for track in accepted {
            nextTracks[track.id] = track
            nextStates[track.id] = DownloadUpdate(id: track.id, state: .queued, progress: 0, error: nil)
        }
        downloadTracks = nextTracks
        downloadStates = nextStates
        syncDownloadRows(accepted.map(\.id))
        let count = accepted.count
        showToast(count == 0 ? "Déjà téléchargé ou en cours" : count == 1 ? "1 téléchargement ajouté" : "\(count) téléchargements ajoutés")
    }

    /// Ordre de la file de téléchargement (pour l'écran Téléchargements).
    var downloadQueueOrder: [Int64] { BackgroundDownloadManager.shared.queueOrder }

    func cancelDownload(_ id: Int64) {
        BackgroundDownloadManager.shared.cancel(id)
    }

    func cancelAllDownloads() {
        BackgroundDownloadManager.shared.stopAll()
        showToast("Téléchargements arrêtés")
    }

    /// Retire de la liste les téléchargements en échec.
    func clearFailedDownloads() {
        BackgroundDownloadManager.shared.clearFailed()
    }

    func removeDownload(_ id: Int64) {
        guard let core else { return }
        BackgroundDownloadManager.shared.cancel(id)
        do {
            try core.removeDownload(id: id)
            forgetOfflineDetails()
            refreshDownloads()
        } catch { message = describe(error) }
    }

    func removeDownloadCollection(_ collection: DownloadCollection) {
        guard let core else { return }
        do {
            let ids = try core.removeDownloadCollection(kind: collection.kind, id: collection.id)
            BackgroundDownloadManager.shared.cancel(ids)
            // Copies hors ligne gardées en mémoire : elles montraient encore la collection supprimée.
            forgetOfflineDetails()
            refreshDownloads()
            showToast("\(collection.title) supprimé des téléchargements")
        } catch { message = describe(error) }
    }

    func clearDownloads() {
        guard let core else { return }
        BackgroundDownloadManager.shared.stopAll()
        do {
            try core.clearDownloads()
            downloadStates = [:]
            downloadTracks = [:]
            refreshDownloads()
            showToast("Téléchargements effacés")
        } catch { message = describe(error) }
    }

    func restoreDownloadQueue(_ tracks: [Track]) {
        var nextTracks = downloadTracks
        var nextStates = downloadStates
        for track in tracks where !downloadedIds.contains(track.id) {
            nextTracks[track.id] = track
            nextStates[track.id] = DownloadUpdate(id: track.id, state: .queued, progress: 0, error: nil)
        }
        downloadTracks = nextTracks
        downloadStates = nextStates
        syncDownloadRows(tracks.map(\.id))
    }

    func downloadUpdated(_ update: DownloadUpdate) {
        downloadStates[update.id] = update
        syncDownloadRows([update.id])
    }

    func downloadCompleted(_ track: Track) {
        downloadStates[track.id] = nil
        downloadTracks[track.id] = nil
        downloadedIds.insert(track.id)
        syncDownloadRows([track.id])
        scheduleDownloadsRefresh()
    }

    func downloadCancelled(_ id: Int64) {
        downloadStates[id] = nil
        downloadTracks[id] = nil
        syncDownloadRows([id])
    }

    func downloadsStopped(_ ids: [Int64]) {
        var nextTracks = downloadTracks
        var nextStates = downloadStates
        for id in ids {
            nextTracks[id] = nil
            nextStates[id] = nil
        }
        downloadTracks = nextTracks
        downloadStates = nextStates
        syncDownloadRows(ids)
    }

    func downloadQueuePersistenceFailed() {
        showToast("La file de téléchargement n'a pas pu être enregistrée", seconds: 4)
    }

    func observeDownloads(_ status: TrackDownloadStatus, for id: Int64) {
        // Ligne passée à un autre titre : elle ne suit plus l'ancien. Sinon, chaque changement de l'ancien titre
        // (progression, fin, suppression) s'affichait sur cette ligne à la place de l'état du nouveau.
        if let old = status.id, old != id, let previous = downloadRows[old] {
            let others = previous.filter { $0.value != nil && $0.value !== status }
            downloadRows[old] = others.isEmpty ? nil : others
        }
        if status.id != id { status.id = id }
        var rows = (downloadRows[id] ?? []).filter { $0.value != nil && $0.value !== status }
        rows.append(WeakTrackDownloadStatus(status))
        downloadRows[id] = rows
        syncDownloadRows([id])
    }

    private func syncDownloadRows(_ ids: [Int64]? = nil) {
        for id in ids ?? Array(downloadRows.keys) {
            let alive = (downloadRows[id] ?? []).compactMap(\.value)
            guard !alive.isEmpty else {
                downloadRows[id] = nil
                continue
            }
            if alive.count != downloadRows[id]?.count { downloadRows[id] = alive.map(WeakTrackDownloadStatus.init) }
            let update = downloadStates[id]
            let downloaded = downloadedIds.contains(id)
            for status in alive {
                if status.update != update { status.update = update }
                if status.downloaded != downloaded { status.downloaded = downloaded }
            }
        }
    }

    /// Après un titre terminé : listes relues hors du thread principal (le cœur convertit tous les titres téléchargés
    /// et vérifie chaque pochette sur le disque), une seule fois pour plusieurs titres qui finissent à la suite.
    /// L'icône « téléchargé » du titre, elle, est déjà à jour (`downloadCompleted`).
    private func scheduleDownloadsRefresh() {
        guard downloadsRefreshTask == nil, let core else { return }
        let version = downloadsVersion
        downloadsRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let lists = await Task.detached(priority: .utility) {
                (Set(core.downloads().map(\.id)), core.standaloneDownloads(), core.downloadCollections())
            }.value
            guard !Task.isCancelled, let self, version == self.downloadsVersion else { return }
            self.downloadsRefreshTask = nil
            if self.downloadedIds != lists.0 { self.downloadedIds = lists.0 }
            self.downloads = lists.1
            self.downloadCollections = lists.2
            self.refreshDownloadBytes()
            self.syncDownloadRows()
        }
    }

    /// Mise à jour immédiate (après une action de l'utilisateur, dont la suite lit les listes tout de suite).
    private func refreshDownloads() {
        guard let core else { return }
        cancelBackgroundDownloadsRefresh()
        let all = core.downloads()
        downloadedIds = Set(all.map(\.id))
        downloads = core.standaloneDownloads()
        downloadCollections = core.downloadCollections()
        refreshDownloadBytes()
        syncDownloadRows()
    }

    private func cancelBackgroundDownloadsRefresh() {
        downloadsVersion &+= 1
        downloadsRefreshTask?.cancel()
        downloadsRefreshTask = nil
    }

    /// Taille occupée : calculée hors du thread principal (le cœur parcourt tout le dossier des téléchargements).
    private func refreshDownloadBytes() {
        guard let core else { return }
        bytesTask?.cancel()
        bytesTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) { core.downloadBytes() }.value
            guard !Task.isCancelled, let self else { return }
            if self.downloadBytes != bytes { self.downloadBytes = bytes }
        }
    }

    /// Titre dont les crédits sont affichés (feuille ouverte par-dessus l'app).
    var creditsTrack: Track?

    func credits(_ id: Int64) async -> Credits? {
        guard let core else { return nil }
        return try? await core.credits(id: id)
    }

    /// Titres aimés affichés sur l'accueil (sinon ils sont dans la bibliothèque).
    private(set) var lovedOnHome = UserDefaults.standard.object(forKey: "lovedOnHome") as? Bool ?? true

    func setLovedOnHome(_ on: Bool) {
        lovedOnHome = on
        UserDefaults.standard.set(on, forKey: "lovedOnHome")
        showToast(on ? tr("%@ affichés sur l'accueil", lovedTitle) : tr("%@ déplacés dans la bibliothèque", lovedTitle))
    }

    /// Nom des titres aimés, choisi sur ce téléphone (rien n'est envoyé à Deezer). Utilisé partout où ils apparaissent.
    /// Nom choisi sur ce téléphone ; sinon celui d'origine, dans la langue de l'app.
    private var customLovedTitle = UserDefaults.standard.string(forKey: "lovedTitle")
    var lovedTitle: String { customLovedTitle ?? tr(Player.defaultLovedTitle) }
    static let defaultLovedTitle = "Titres aimés"
    /// Fenêtre « Renommer » ouverte.
    var renamingLoved = false

    func setLovedTitle(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(clean.prefix(60))
        if title.isEmpty || title == Player.defaultLovedTitle || title == tr(Player.defaultLovedTitle) {
            customLovedTitle = nil
            UserDefaults.standard.removeObject(forKey: "lovedTitle")
        } else {
            customLovedTitle = title
            UserDefaults.standard.set(title, forKey: "lovedTitle")
        }
    }

    /// Titres aimés vus comme une carte (menus de pochette et de téléchargement).
    var lovedMenuCard: Card { Card(kind: "loved", id: 0, title: lovedTitle, subtitle: "", coverUrl: nil, owned: true, key: "") }
    /// Flow vu comme une carte (menu de pochette).
    static let flowCard = Card(kind: "flow", id: 0, title: "Flow", subtitle: "", coverUrl: nil, owned: false, key: "")
    /// Pochette de Flow choisie sur ce téléphone (nil : la vague sur la couleur du thème).
    var flowCover: String? { customCovers["flow"] }

    /// Ordre des éléments du haut de l'accueil (Flow, Titres aimés, épinglés), réglé en les faisant glisser.
    private(set) var homeOrder: [String] = UserDefaults.standard.stringArray(forKey: "homeOrder") ?? []

    var homeItems: [HomeItem] {
        var all: [HomeItem] = []
        if flowOnHome { all.append(.flow) }
        if lovedOnHome { all.append(.loved) }
        all += pins.map { .pin($0) }
        let rank = Dictionary(homeOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Éléments jamais déplacés : après les autres, dans leur ordre naturel.
        return all.enumerated()
            .sorted { (rank[$0.element.id] ?? 10_000 + $0.offset) < (rank[$1.element.id] ?? 10_000 + $1.offset) }
            .map { $0.element }
    }

    /// Nouvel ordre complet (écran « Réorganiser l'accueil »).
    func setHomeOrder(_ ids: [String]) {
        homeOrder = ids
        UserDefaults.standard.set(ids, forKey: "homeOrder")
    }

    /// Flow affiché sur l'accueil (sinon il est dans la bibliothèque).
    private(set) var flowOnHome = UserDefaults.standard.object(forKey: "flowOnHome") as? Bool ?? true

    func setFlowOnHome(_ on: Bool) {
        flowOnHome = on
        UserDefaults.standard.set(on, forKey: "flowOnHome")
        showToast(on ? tr("Flow affiché sur l'accueil") : tr("Flow déplacé dans la bibliothèque"))
    }

    /// Paroles déjà demandées (30 titres au plus) et titres sans paroles sur Deezer.
    @ObservationIgnored private var lyricsCache: [Int64: Lyrics] = [:]
    @ObservationIgnored private var noLyrics: Set<Int64> = []

    /// Paroles Deezer du titre ; `nil` s'il n'en a pas (ou si Deezer ne répond pas).
    func lyrics(_ id: Int64) async -> Lyrics? {
        if let hit = lyricsCache[id] { return hit }
        guard let core, !noLyrics.contains(id) else { return nil }
        do {
            guard let found = try await core.lyrics(id: id) else {
                noLyrics.insert(id)
                return nil
            }
            if lyricsCache.count >= 30 { lyricsCache.removeAll() }
            lyricsCache[id] = found
            return found
        } catch {
            return nil
        }
    }

    /// Un titre plus loin ou plus tôt dans la file, sans la règle « précédent = retour au début »
    /// (glissement sur une pochette : on va toujours sur la voisine affichée).
    func step(_ delta: Int) { skip(delta) }

    /// Historique de recherche (comme sur le bureau).
    private(set) var history: [HistoryEntry] = HistoryEntry.load()

    func remember(_ entry: HistoryEntry) {
        history = [entry] + history.filter { $0.key != entry.key }
        if history.count > HistoryEntry.limit { history.removeLast(history.count - HistoryEntry.limit) }
        HistoryEntry.save(history)
    }

    /// Entrée d'historique créée sans image (artiste ouvert depuis le menu d'un titre) : elle prend celle de la page ouverte.
    private func fillHistoryCover(kind: String, id: UInt64, cover: String?) {
        guard let cover, let i = history.firstIndex(where: { $0.kind == .card && $0.card?.kind == kind && $0.card?.id == id && $0.card?.coverUrl == nil }) else { return }
        history[i].card?.coverUrl = cover
        HistoryEntry.save(history)
    }

    func forget(_ entry: HistoryEntry) {
        history.removeAll { $0.key == entry.key }
        HistoryEntry.save(history)
    }

    func clearHistory() {
        history = []
        HistoryEntry.save(history)
    }

    /// Lance un titre de l'historique : sa fiche est redemandée à Deezer si le cœur ne la connaît plus.
    func playHistoryTrack(_ entry: HistoryEntry) {
        guard let core, let id = entry.trackId else { return }
        pendingRestore = nil
        activateOutput()
        current = Track(id: id, title: entry.title ?? "", artist: entry.subtitle ?? "", album: "", durationS: 0, coverUrl: entry.coverUrl,
                        quality: nil, artistId: 0, albumId: 0, addedAt: nil, releaseDate: nil, artists: [])
        isFlow = false
        startLoading()
        Task {
            do { try await core.playById(id: id) } catch { loading = false; showToast(describe(error), seconds: 4) }
        }
    }

    /// Playlists, albums, artistes épinglés sur l'accueil.
    private(set) var pins: [Pin] = Pin.load()
    /// Flow en cours : la file se renouvelle seule, il y a toujours un titre suivant.
    private(set) var isFlow = false

    var hasNext: Bool { shownIndex + 1 < queue.count || repeatMode == .all || isFlow }
    /// Toujours actif avec un titre : sur le premier de la file, il le relance depuis le début.
    var hasPrevious: Bool { current != nil }

    func isPinned(_ card: Card) -> Bool { pins.contains { $0.matches(card) } }

    func togglePin(_ card: Card) {
        if let i = pins.firstIndex(where: { $0.matches(card) }) {
            let removed = HomeItem.pin(pins[i]).id
            pins.remove(at: i)
            if homeOrder.contains(removed) { setHomeOrder(homeOrder.filter { $0 != removed }) }
            showToast(tr("Retiré de l'accueil"))
        } else {
            pins.append(Pin(card))
            showToast(tr("Épinglé sur l'accueil"))
        }
        Pin.save(pins)
    }

    /// Pochette ou nom changés sur Deezer (playlist communautaire qui change d'image…) : l'épinglé suit.
    private func refreshPins(_ cards: [Card]) {
        var changed = false
        for card in cards {
            guard let i = pins.firstIndex(where: { $0.matches(card) }) else { continue }
            let pin = pins[i]
            let cover = card.coverUrl ?? pin.coverUrl
            guard cover != pin.coverUrl || card.title != pin.title else { continue }
            pins[i].coverUrl = cover
            if !card.title.isEmpty { pins[i].title = card.title }
            changed = true
        }
        if changed { Pin.save(pins) }
    }

    /// Recommandations affichées sur l'accueil (réglables dans Réglages).
    private(set) var reco = RecoPrefs.load()
    /// Confirmation discrète en haut de l'écran (pas une alerte à fermer).
    private(set) var toast: String?
    @ObservationIgnored private var toastGeneration = 0
    /// Égaliseur 5 bandes : préréglage choisi (« Désactivé » : son d'origine) et réglages « Personnalisé », gardés sur
    /// le téléphone (un réglage de l'ancien égaliseur 3 bandes est repris par son équivalent).
    private(set) var eqPreset: EqPreset = EqPreset(saved: UserDefaults.standard.string(forKey: "eqPreset") ?? "") ?? .off
    /// Dernier préréglage actif : rallumer l'égaliseur le reprend.
    private(set) var eqLast: EqPreset = EqPreset(saved: UserDefaults.standard.string(forKey: "eqLast") ?? "") ?? .bassBoost
    private(set) var eqCustom: [Double] = {
        let saved = UserDefaults.standard.array(forKey: "eqCustom") as? [Double] ?? []
        switch saved.count {
        case 5: return saved
        case 3: return EqPreset.fromThreeBands(saved)
        default: return [0, 0, 0, 0, 0]
        }
    }()

    /// Gains affichés par les curseurs (ceux du préréglage, ou les réglages perso).
    var eqGains: [Double] { eqPreset.gains ?? eqCustom }

    func setEqPreset(_ preset: EqPreset) {
        eqPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "eqPreset")
        if preset != .off {
            eqLast = preset
            UserDefaults.standard.set(preset.rawValue, forKey: "eqLast")
        }
        applyEq()
    }

    /// Interrupteur : rallumé, l'égaliseur reprend le dernier préréglage utilisé.
    func setEqOn(_ on: Bool) {
        setEqPreset(on ? (eqLast == .off ? .bassBoost : eqLast) : .off)
    }

    /// Flèches : préréglage précédent (-1) ou suivant (+1), en boucle ; « Personnalisé » en fait partie (on y revient
    /// sans toucher un curseur, qui le remplacerait par le préréglage affiché).
    func stepEqPreset(_ delta: Int) {
        let list = EqPreset.named + [.custom]
        let i = list.firstIndex(of: eqPreset) ?? (delta > 0 ? -1 : list.count)
        setEqPreset(list[((i + delta) % list.count + list.count) % list.count])
    }

    /// Une bande (0 = 60 Hz … 4 = 14 kHz), de -12 à +12 dB. Sur un préréglage, ses réglages sont d'abord recopiés dans
    /// « Personnalisé » : on part de ce qu'on entend.
    func setEqBand(_ band: Int, _ db: Double) {
        guard (0..<5).contains(band) else { return }
        if eqPreset != .custom { eqCustom = eqGains }
        eqCustom[band] = min(max(db, -12), 12)
        UserDefaults.standard.set(eqCustom, forKey: "eqCustom")
        if eqPreset == .custom { applyEq() } else { setEqPreset(.custom) }
    }

    /// Fondu enchaîné entre deux titres, en secondes (0 = désactivé), gardé sur le téléphone.
    private(set) var crossfade: Int = min(max(UserDefaults.standard.integer(forKey: "crossfade"), 0), 10)

    func setCrossfade(_ seconds: Int) {
        crossfade = min(max(seconds, 0), 10)
        if crossfade == 0 { UserDefaults.standard.removeObject(forKey: "crossfade") } else { UserDefaults.standard.set(crossfade, forKey: "crossfade") }
        core?.setCrossfade(seconds: UInt32(crossfade))
    }

    /// Envoyé au moteur ; il l'applique aussitôt, sans couper le son.
    private func applyEq() {
        core?.setEq(gains: eqGains.map { Float($0) })
    }

    /// Quand relancer la musique toute seule (coupures, écouteurs) : voir `ResumePolicy`.
    @ObservationIgnored private var resumePolicy = ResumePolicy()

    /// Réglage : reprendre la dernière écoute au relancement de l'app (activé par défaut).
    private(set) var resumeOnLaunch = UserDefaults.standard.object(forKey: "resumeOnLaunch") as? Bool ?? true

    func setResumeOnLaunch(_ on: Bool) {
        resumeOnLaunch = on
        UserDefaults.standard.set(on, forKey: "resumeOnLaunch")
        if !on { LastSession.clear() } // plus rien de gardé
    }

    /// Dernière écoute retrouvée au lancement, pas encore relancée (voir `LastSession`) : le premier appui la reprend.
    @ObservationIgnored private var pendingRestore: LastSession?
    /// Sortie audio arrêtée par iOS (appel, redémarrage du service audio) : à rouvrir au prochain appui sur lecture.
    @ObservationIgnored private var needsReopen = false

    private init() {
        // La catégorie doit être posée avant que le cœur n'ouvre la sortie audio.
        AudioSession.configure()
        // Sortie AVAudioEngine branchée avant le cœur : il la démarre dès le premier titre.
        AudioOutput.install()
        var startError: String?
        let files = FileManager.default
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("deezer-lite")
        var storage = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("deezer-lite/Downloads", isDirectory: true)
        // Premier lancement après une installation : le dossier de l'app n'existe pas encore (créé juste en dessous, à
        // chaque lancement ; une mise à jour le garde). Une session laissée dans le trousseau par une installation
        // supprimée est alors effacée : supprimer l'app efface vraiment tout.
        if !files.fileExists(atPath: storage.deletingLastPathComponent().path) {
            KeychainAccess.forgetSession()
        }
        do {
            try files.createDirectory(at: storage, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try? storage.setResourceValues(resources)
            try? files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: storage.path)
            let core = try Core(listener: events, cacheDir: caches.path, downloadDir: storage.path)
            self.core = core
            // Compte Famille : le profil choisi la dernière fois est rouvert dès la connexion.
            core.setProfile(id: Self.savedProfile)
            core.setDownloadQuality(quality: downloadQuality)
            let all = core.downloads()
            downloadedIds = Set(all.map(\.id))
            downloads = core.standaloneDownloads()
            downloadCollections = core.downloadCollections()
        } catch {
            core = nil
            startError = "Démarrage impossible : \(error)"
        }
        message = startError
        events.player = self
        refreshDownloadBytes()
        // Pas de volume dans l'app : c'est celui de l'iPhone qui compte. Le moteur joue à 100 % : même niveau que les
        // autres apps, et le son sort sans retouche quand l'égaliseur est désactivé (il démarrait à 50 %, réglage de la
        // version bureau). Une bande d'égaliseur remontée active le limiteur doux : pas de saturation.
        core?.setVolume(volume: 1.0)
        applyEq()
        core?.setCrossfade(seconds: UInt32(crossfade))
        // Créé ici, au lancement : une relance en arrière-plan pour livrer des téléchargements trouve le cœur prêt.
        if let core { BackgroundDownloadManager.shared.configure(core: core, player: self) }
        // Qualité choisie lors d'une session précédente (le cœur démarre en FLAC).
        applyQuality()
        watchNetwork()
        NowPlaying.setup(self)
        observeAudioSession()
        // Mémoire sous pression ou passage en arrière-plan : on oublie les pages et paroles gardées en mémoire
        // (redemandées au besoin) ; en arrière-plan, l'app ne garde que le strict nécessaire pour jouer.
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trimMemory() }
            }
        }
        // iOS peut fermer l'app en arrière-plan : la dernière écoute est gardée pour la reprendre au lancement.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLastSession() }
            }
        }
        // Verrouillage, Centre de contrôle, passage en arrière-plan : l'écran verrouillé repart de l'état réel du moteur.
        // Retour dans l'app (sélecteur d'apps, écran verrouillé) : position et lecture relues tout de suite.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Ouverture de session ratée plus tôt (Wi-Fi lent, portail…) : retentée au retour dans l'app.
                self?.retrySessionIfNeeded()
            }
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
        }
        // ARL lisible même iPhone verrouillé (CarPlay peut lancer l'app téléphone dans la poche).
        KeychainAccess.allowWhileLocked()
        // Lancée iPhone verrouillé avant que ce réglage ne soit posé : la session est rouverte au déverrouillage.
        if !UIApplication.shared.isProtectedDataAvailable {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    KeychainAccess.allowWhileLocked()
                    guard let self, !self.sessionReady else { return }
                    if let core = self.core, self.loggedIn != true, core.hasSavedLogin() {
                        self.loggedIn = true
                        Task { await self.showSavedCopy(core) }
                    }
                    Task { await self.restore() }
                }
            }
        }
        // Déjà connecté : l'app s'ouvre tout de suite sur la dernière copie (accueil, bibliothèque),
        // pendant que la session Deezer s'ouvre en arrière-plan.
        if let core, core.hasSavedLogin() {
            loggedIn = true
            if resumeOnLaunch, let last = LastSession.load() { showLastSession(last) }
            Task { await showSavedCopy(core) }
        } else {
            launchReady = true
        }
        Task { await restore() }
    }

    /// Copies du téléphone affichées (ou rien à afficher) : l'écran de lancement peut s'effacer.
    private(set) var launchReady = false

    /// Copies de l'accueil, de la bibliothèque et des titres aimés lues sur le téléphone.
    private struct SavedCopy: @unchecked Sendable {
        var home: [Shelf]
        var library: [[Card]]
        var loved: [Int64]
        var lovedCard: Card?
    }

    /// Lues hors du thread principal (avant, l'écran attendait ces lectures pour s'afficher), pendant l'animation de
    /// lancement. Ce qui est déjà arrivé de Deezer entre-temps n'est pas remplacé par la copie.
    private func showSavedCopy(_ core: Core) async {
        let wantHome = reco.anyVisible
        let gen = profileGeneration
        let copy = await Task.detached(priority: .userInitiated) {
            SavedCopy(home: wantHome ? core.cachedHome() : [],
                      library: (0...2).map { core.cachedLibrary(tab: UInt8($0)) },
                      loved: core.cachedLovedIds(),
                      lovedCard: core.cachedLovedCard())
        }.value
        defer { launchReady = true }
        // Session refusée ou profil changé pendant la lecture : ces copies ne sont plus les bonnes.
        guard gen == profileGeneration else { return }
        if home == nil, !copy.home.isEmpty { home = copy.home }
        for (tab, list) in copy.library.enumerated() where library[tab] == nil && !list.isEmpty { library[tab] = list }
        if lovedIds.isEmpty { lovedIds = Set(copy.loved) }
        if lovedCard == nil { lovedCard = copy.lovedCard }
    }

    /// L'app rouverte après qu'iOS l'a fermée : même titre, même file, même position, en pause.
    private func showLastSession(_ last: LastSession) {
        let tracks = last.tracks.map(\.track)
        guard tracks.indices.contains(last.index) else { return }
        queue = tracks
        queueIndex = last.index
        shownIndex = last.index
        current = tracks[last.index]
        status = Status(playing: false, positionMs: last.positionMs, durationMs: tracks[last.index].durationS * 1000)
        statusAt = Date()
        pendingRestore = last
    }

    /// Garde la dernière écoute (passage en arrière-plan, fermeture) ; rien à garder si aucun titre.
    private func saveLastSession() {
        guard resumeOnLaunch else { LastSession.clear(); return }
        if pendingRestore != nil { return } // déjà gardée, pas encore relancée
        guard current != nil, let last = LastSession(queue: queue, index: queueIndex, positionMs: UInt64(max(0, position(at: Date())) * 1000)) else {
            LastSession.clear()
            return
        }
        last.save()
    }

    /// Relance la dernière écoute au titre `index` (et à `position` s'il s'agit du titre gardé).
    private func restoreLastSession(_ last: LastSession, index: Int, position: UInt64) {
        guard let core, queue.indices.contains(index) else { return }
        pendingRestore = nil
        activateOutput()
        current = queue[index]
        shownIndex = index
        startLoading()
        let ids = last.tracks.map(\.id)
        Task {
            do {
                try await core.restoreQueue(ids: ids, index: UInt32(index), positionMs: index == last.index ? position : 0)
            } catch {
                loading = false
                showToast(describe(error), seconds: 4)
            }
        }
    }

    // MARK: Profils (compte Deezer Famille)

    /// Profils du compte (compte solo : le compte seul). Vide tant qu'ils ne sont pas chargés.
    private(set) var profiles: [Profile] = []
    /// Fenêtre « Qui écoute ? » ouverte.
    var choosingProfile = false
    /// Changement de profil en cours (les profils ne sont plus appuyables).
    private(set) var switchingProfile = false
    /// Réglages ouverts : « Qui écoute ? » s'affiche par-dessus eux (iOS ne montre qu'une fenêtre à la fois depuis
    /// un même écran ; sinon la question n'apparaissait pas).
    var settingsOpen = false
    /// Change à chaque changement de profil (et à la déconnexion) : une réponse de Deezer demandée pour le profil
    /// d'avant, arrivée après, n'est pas affichée.
    @ObservationIgnored private var profileGeneration = 0
    /// Change à chaque profil ouvert : les pages ouvertes (album, playlist, Titres aimés) sont refermées, les onglets de
    /// la bibliothèque rechargés ; elles montraient encore le profil d'avant.
    private(set) var profileEpoch = 0
    var currentProfile: Profile? { profiles.first { $0.current } }
    /// Compte Famille : plusieurs profils à choisir.
    var isFamily: Bool { profiles.count > 1 }

    /// Profil choisi la dernière fois, gardé sur le téléphone et rouvert à chaque lancement.
    private static var savedProfile: UInt64? {
        get { (UserDefaults.standard.object(forKey: "profileId") as? NSNumber)?.uint64Value }
        set {
            if let newValue { UserDefaults.standard.set(NSNumber(value: newValue), forKey: "profileId") } else { UserDefaults.standard.removeObject(forKey: "profileId") }
        }
    }

    /// Session ouverte : profils chargés. Compte Famille sans choix enregistré : « Qui écoute ? ».
    private func loadProfiles() async {
        guard loggedIn == true, let core, let list = try? await core.profiles() else { return }
        // Déconnexion pendant la lecture de la liste : rien n'est affiché.
        guard loggedIn == true else { return }
        profiles = list
        // Choix laissé par un autre compte (connexion après expiration…) : oublié sans message, et plus redemandé à
        // Deezer. Un choix présent dans la liste reste (liste incomplète vue d'un profil enfant : il y est toujours).
        if let saved = Self.savedProfile, !list.contains(where: { $0.id == saved }) {
            Self.savedProfile = nil
            core.setProfile(id: nil)
        }
        guard list.count > 1 else { return }
        let current = list.first { $0.current }
        guard let saved = Self.savedProfile else {
            choosingProfile = true
            return
        }
        // Profil choisi devenu inaccessible (retiré du compte…) : le cœur a ouvert le titulaire.
        if current?.id != saved {
            Self.savedProfile = nil
            showToast(tr("Ton profil n'est plus accessible : %@ est ouvert.", current?.name ?? tr("profil principal")), seconds: 4)
            choosingProfile = true
        }
    }

    /// Ouvre un profil : bibliothèque, titres aimés et recommandations deviennent les siens ; la lecture continue.
    func switchProfile(_ p: Profile) async {
        guard let core, !switchingProfile else { return }
        if p.current {
            Self.savedProfile = p.id
            choosingProfile = false
            return
        }
        switchingProfile = true
        defer { switchingProfile = false }
        do {
            try await core.switchProfile(id: p.id)
            // Déconnexion pendant le changement : rien n'est gardé pour le compte suivant.
            guard loggedIn == true else { return }
            Self.savedProfile = p.id
            choosingProfile = false
            profileGeneration += 1
            profileEpoch += 1
            // Onglets de la bibliothèque déjà ouverts (albums, artistes) : rechargés aussi, sinon ils restaient vides.
            let openTabs = library.keys.filter { $0 != 0 }
            forgetProfilePages()
            // Liste relue ; sinon, la même avec le nouveau profil marqué ouvert.
            let marked = profiles.map { var q = $0; q.current = q.id == p.id; return q }
            let fresh = try? await core.profiles()
            guard loggedIn == true else { return } // déconnecté pendant ce temps
            profiles = fresh ?? marked
            showToast(tr("Profil : %@", p.name))
            // Titres aimés téléchargés : ceux de ce profil (le cœur garde ceux de chaque profil à part).
            refreshDownloads()
            prefetch()
            for tab in openTabs { Task { await loadLibrary(tab, force: false) } }
        } catch {
            showToast(describe(error), seconds: 4)
        }
    }

    /// « Qui écoute ? » fermé sans choisir : le profil ouvert est gardé (la question n'est plus posée).
    func keepCurrentProfile() {
        if Self.savedProfile == nil, let id = currentProfile?.id { Self.savedProfile = id }
    }

    /// Ce qui venait du profil d'avant : accueil, bibliothèque, titres aimés, pages ouvertes, paroles.
    private func forgetProfilePages() {
        home = nil
        library = [:]
        details = [:]
        detailOrder = []
        refreshed = []
        lovedIds = []
        lovedCard = nil
        lyricsCache = [:]
        noLyrics = []
    }

    // MARK: Compte

    /// Session Deezer ouverte : avant, les chargements gardent la copie locale au lieu de lancer leurs requêtes en double.
    @ObservationIgnored private var sessionReady = false
    /// Ce qui a déjà été actualisé depuis le lancement (le reste l'est à la première visite, copie affichée en attendant).
    @ObservationIgnored private var refreshed: Set<String> = []

    /// Une seule ouverture de session à la fois : avant, un retour du réseau pendant celle du lancement en lançait une
    /// seconde (accueil, bibliothèque et synchro des téléchargements chargés deux fois).
    private func restore() async {
        guard let core else { loggedIn = false; return }
        guard !restoringSession, !sessionReady else { return }
        restoringSession = true
        defer { restoringSession = false }
        let account = accountGeneration
        do {
            let ok = try await core.restoreSession()
            // Déconnexion pendant l'attente : la réponse ne rouvre pas le compte.
            guard account == accountGeneration else { return }
            loggedIn = ok
            if !ok { forgetAccountCopies() }
            if ok {
                sessionRetries = 0
                sessionRetryTask?.cancel()
                sessionRetryTask = nil
                sessionReady = true
                forgetOfflineDetails()
                // Profil ouvert maintenant connu : la liste des téléchargements montre ses Titres aimés à lui.
                refreshDownloads()
                BackgroundDownloadManager.shared.deezerSessionIsReady()
                prefetch()
                await loadProfiles()
            }
        } catch {
            guard account == accountGeneration else { return }
            // Réseau absent : on garde la copie locale si on en a une, sans message (l'erreur n'apparaît que si l'on
            // demande quelque chose qui a besoin du réseau). La session est rouverte dès que le réseau revient.
            // Réseau là mais Deezer injoignable (Wi-Fi lent, portail) : le type de réseau ne change pas, donc rien ne
            // la relançait. Nouvel essai après 5 s, 15 s puis 60 s, et à chaque retour dans l'app.
            if loggedIn == true { scheduleSessionRetry() }
            if loggedIn != true {
                loggedIn = false
                // iPhone verrouillé (trousseau illisible) : pas de message, nouvel essai au déverrouillage.
                if UIApplication.shared.isProtectedDataAvailable { message = describe(error) }
            }
        }
    }

    @ObservationIgnored private var sessionRetries = 0
    @ObservationIgnored private var sessionRetryTask: Task<Void, Never>?

    private func scheduleSessionRetry() {
        guard sessionRetryTask == nil, sessionRetries < 3, networkSignature != "none" else { return }
        let delays: [Duration] = [.seconds(5), .seconds(15), .seconds(60)]
        let delay = delays[sessionRetries]
        sessionRetries += 1
        sessionRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.sessionRetryTask = nil
            self.retrySessionIfNeeded()
        }
    }

    /// CarPlay connecté ou utilisé : nouvel essai d'ouverture de session (les essais automatiques ont pu s'arrêter, et le
    /// retour dans l'app qui les relance n'arrive jamais avec l'iPhone dans la poche).
    func retrySessionFromCarPlay() {
        sessionRetries = 0
        retrySessionIfNeeded()
    }

    private func retrySessionIfNeeded() {
        guard loggedIn == true, !sessionReady, !restoringSession, networkSignature != "none" else { return }
        Task { await restore() }
    }

    func login(arl: String) async {
        guard let core else { return }
        do {
            try await core.login(arl: arl)
            KeychainAccess.allowWhileLocked()
            loggedIn = true
            sessionReady = true
            BackgroundDownloadManager.shared.deezerSessionIsReady()
            prefetch()
            await loadProfiles()
        } catch { message = describe(error) }
    }

    /// Session expirée : les copies affichées au lancement ne restent pas en mémoire (la connexion suivante peut être
    /// celle d'un autre compte). Les téléchargements ne sont pas concernés.
    private func forgetAccountCopies() {
        // Plus de compte ouvert : la musique s'arrête et l'écran verrouillé se vide (avant, le son continuait derrière
        // l'écran de connexion).
        attempt { try $0.pause() }
        status = Status(playing: false, positionMs: 0, durationMs: 0)
        loading = false
        isFlow = false
        NowPlaying.update(track: nil, status: status)
        profileGeneration += 1
        profileEpoch += 1
        lovedIds = []
        queue = []
        queueIndex = 0
        shownIndex = 0
        current = nil
        home = nil
        library = [:]
        details = [:]
        detailOrder = []
        refreshed = []
        coverFixes = [:]
        pendingRestore = nil
        LastSession.clear()
    }

    /// Change à chaque déconnexion : une ouverture de session lancée avant ne rouvre pas le compte.
    @ObservationIgnored private var accountGeneration = 0

    func logout() async {
        guard let core else { return }
        accountGeneration += 1
        BackgroundDownloadManager.shared.stopAll()
        do { try await core.logout() } catch { message = describe(error) }
        // Profil choisi oublié : un autre compte peut se connecter.
        Self.savedProfile = nil
        profileGeneration += 1
        settingsOpen = false
        profiles = []
        choosingProfile = false
        // Plus rien du compte en mémoire ni sur le téléphone (le cœur a déjà effacé session, cookies, trousseau et copies).
        bytesTask?.cancel()
        bytesTask = nil
        cancelBackgroundDownloadsRefresh()
        downloads = []
        downloadCollections = []
        downloadedIds = []
        downloadStates = [:]
        downloadTracks = [:]
        downloadBytes = 0
        syncDownloadRows()
        lovedIds = []
        queue = []
        queueIndex = 0
        shownIndex = 0
        current = nil
        status = Status(playing: false, positionMs: 0, durationMs: 0)
        loading = false
        isFlow = false
        home = nil
        library = [:]
        details = [:]
        detailOrder = []
        refreshed = []
        lyricsCache = [:]
        noLyrics = []
        likeTasks = [:]
        likeGeneration = [:]
        creditsTrack = nil
        showFullPlayer = false
        clearHistory()
        pendingRestore = nil
        LastSession.clear()
        pins = []
        Pin.save(pins)
        homeOrder = []
        UserDefaults.standard.removeObject(forKey: "homeOrder")
        setLovedTitle("")
        coverTarget = nil
        pickingCover = false
        lovedCard = nil
        customCovers = [:]
        CustomCovers.store(customCovers)
        CustomCovers.removeAll()
        CoverLoader.shared.clear()
        NowPlaying.update(track: nil, status: status)
        // Plus aucune reprise automatique en attente.
        resumePolicy = ResumePolicy()
        AudioSession.deactivate()
        AudioSession.configure()
        sessionReady = false
        loggedIn = false
    }

    /// Dès la connexion, en parallèle : accueil, bibliothèque et nouveaux titres des collections hors ligne.
    private func prefetch() {
        Task {
            async let h: Void = loadHome(force: false)
            async let p: Void = loadLibrary(0, force: false)
            async let l: Void = refreshLoved()
            async let c: Void = refreshLovedCard()
            async let d: Void = syncDownloadedCollections()
            _ = await (h, p, l, c, d)
            await refreshPinCovers()
        }
    }

    /// Épinglés absents de l'accueil et de la bibliothèque (playlist communautaire…) : leur fiche est redemandée
    /// une fois par lancement, l'un après l'autre, pour que la pochette affichée sur l'accueil soit la bonne.
    private func refreshPinCovers() async {
        guard let core else { return }
        let known = (library[0] ?? []) + (library[1] ?? []) + (home ?? []).flatMap(\.items)
        let stale = pins.filter { pin in
            ["playlist", "album", "artist"].contains(pin.kind) && !known.contains { pin.matches($0) }
        }
        for pin in stale {
            // Playlist : fiche légère (titre, pochette), sans ses titres. Album, artiste : leur page.
            if pin.kind == "playlist" {
                guard let card = try? await core.playlistCard(id: pin.id) else { continue }
                refreshPins([card])
                continue
            }
            guard let detail = try? await core.openDetail(kind: pin.kind, id: pin.id), !detail.offline else { continue }
            refreshPins([Card(kind: pin.kind, id: pin.id, title: detail.title, subtitle: detail.subtitle,
                              coverUrl: detail.coverUrl, owned: detail.owned, key: pin.key)])
        }
    }

    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    /// Un seul chargement à la fois par clé : un second appel attend le premier au lieu de refaire la requête.
    private func once(_ key: String, _ work: @escaping () async -> Void) async {
        if let running = inFlight[key] { return await running.value }
        let task = Task { await work() }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
    }

    func updateReco(_ change: (inout RecoPrefs) -> Void) {
        change(&reco)
        // Toutes les catégories masquées = recommandations désactivées, comme sur le bureau.
        if reco.enabled && reco.order.allSatisfy(reco.hidden.contains) { reco.enabled = false }
        reco.save()
        if reco.anyVisible && home == nil { Task { await loadHome(force: true) } }
        // Désactivées : rien n'est gardé en mémoire ni redemandé à Deezer (aucun appel tant qu'elles restent coupées).
        if !reco.anyVisible { home = nil }
    }

    func loadHome(force: Bool) async {
        guard sessionReady, reco.anyVisible, force || !refreshed.contains("home") else { return }
        let gen = profileGeneration
        await once("home#\(gen)") {
            // En cas d'erreur, la copie affichée reste. Profil changé entre-temps : réponse ignorée.
            let fresh = await self.load(nil as [Shelf]?, { try await $0.home() })
            guard gen == self.profileGeneration else { return }
            if let fresh {
                self.home = fresh
                self.refreshPins(fresh.flatMap(\.items))
            }
            self.refreshed.insert("home")
        }
    }

    /// 0 = playlists, 1 = albums, 2 = artistes.
    func loadLibrary(_ tab: Int, force: Bool) async {
        let key = "library\(tab)"
        guard sessionReady, force || !refreshed.contains(key) else { return }
        let gen = profileGeneration
        await once("\(key)#\(gen)") {
            let fresh: [Card]? = await self.load(nil as [Card]?) { core in
                switch tab {
                case 0: return try await core.myPlaylists()
                case 1: return try await core.myAlbums()
                default: return try await core.myArtists()
                }
            }
            guard gen == self.profileGeneration else { return } // profil changé entre-temps
            if let fresh {
                self.library[tab] = fresh
                self.refreshPins(fresh)
            }
            self.refreshed.insert(key)
        }
    }

    private func localDetail(_ route: Route) -> Detail? {
        guard let core else { return nil }
        return switch route {
        case .detail(let kind, let id, _): core.offlineDetail(kind: kind, id: id)
        case .loved: core.offlineDetail(kind: "loved", id: 0)
        case .mix: nil
        }
    }

    /// Petit cache : les 12 dernières pages ouvertes (copies hors ligne comprises).
    /// Jour (« AAAA-MM-JJ », heure du téléphone) où chaque page gardée en mémoire a été chargée.
    @ObservationIgnored private var detailDay: [Route: String] = [:]

    private static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Page gardée avec des titres qui n'étaient pas encore sortis à son chargement, et dont la date de sortie est
    /// arrivée : elle est rechargée pour qu'ils se dégrisent tout seuls. Les titres retirés (date déjà passée au
    /// chargement) ne comptent pas : sinon la page serait redemandée à chaque visite.
    private func hasNewReleases(_ detail: Detail, route: Route) -> Bool {
        guard let loaded = detailDay[route] else { return false }
        let today = Self.day()
        guard today > loaded else { return false }
        return detail.tracks.contains { track in
            guard track.unavailable, let release = track.releaseDate.map({ String($0.prefix(10)) }) else { return false }
            return release > loaded && release <= today
        }
    }

    private func cacheDetail(_ detail: Detail, for route: Route) {
        details[route] = detail
        detailDay[route] = Self.day()
        detailOrder.removeAll { $0 == route }
        detailOrder.append(route)
        if detailOrder.count > maxDetails { details[detailOrder.removeFirst()] = nil }
    }

    func cachedDetail(_ route: Route) -> Detail? {
        if networkSignature == "none", let saved = localDetail(route) {
            cacheDetail(saved, for: route)
            return saved
        }
        if let hit = details[route] { return hit }
        return localDetail(route)
    }

    func detail(_ route: Route, force: Bool) async -> Detail? {
        if (!sessionReady || networkSignature == "none"), let saved = localDetail(route) {
            cacheDetail(saved, for: route)
            return saved
        }
        // Copie hors ligne gardée pendant une coupure (ou avant l'ouverture de la session) : plus resservie une fois
        // Deezer joignable, sinon la page restait limitée aux titres du téléphone jusqu'à un rafraîchissement manuel.
        if !force, let hit = details[route], !hit.offline, !hasNewReleases(hit, route: route) { return hit }
        let gen = profileGeneration
        let result: Detail? = await load(nil as Detail?) { core in
            switch route {
            case .detail(let kind, let id, _): return try await core.openDetail(kind: kind, id: id)
            case .mix(let key, _): return try await core.openMix(key: key)
            case .loved:
                return try await core.lovedDetail()
            }
        }
        // Profil changé pendant le chargement : la page s'affiche, mais n'est ni gardée ni reprise ailleurs.
        if let result, gen == profileGeneration {
            cacheDetail(result, for: route)
            // Copie hors ligne : seulement les titres du téléphone, pas la liste complète des aimés.
            if case .loved = route, !result.offline { lovedIds = Set(result.tracks.map(\.id)) }
            if case .detail(let kind, let id, _) = route, !result.offline {
                fillHistoryCover(kind: kind, id: id, cover: result.coverUrl)
                refreshPins([Card(kind: kind, id: id, title: result.title, subtitle: result.subtitle, coverUrl: result.coverUrl,
                                  owned: result.owned, key: "")])
            }
        }
        return result
    }


    // MARK: Catalogue (erreurs affichées une fois, résultat vide)

    func load<T>(_ empty: T, _ body: (Core) async throws -> T) async -> T {
        guard let core else { return empty }
        do { return try await body(core) } catch { showToast(describe(error), seconds: 4); return empty }
    }

    func refreshLoved() async {
        // Deezer ne répond pas : les cœurs déjà connus restent (une liste vide les effaçait tous).
        let gen = profileGeneration
        guard let list = await load(nil as [Track]?, { try await $0.loved() }), gen == profileGeneration else { return }
        lovedIds = Set(list.map(\.id))
    }

    /// Pochettes remplacées dans les listes, par titre (l'image d'origine n'existe plus chez Deezer).
    private(set) var coverFixes: [Int64: String] = [:]

    /// Vérifie les pochettes d'une page une fois affichée ; chaque image n'est vérifiée qu'une fois (le cœur s'en souvient).
    func checkCovers(_ tracks: [Track]) async {
        // Hors ligne : rien à vérifier (chaque requête échouerait), la page sera vérifiée à sa prochaine ouverture.
        guard let core, sessionReady, networkSignature != "none", !tracks.isEmpty else { return }
        guard let fixes = try? await core.checkCovers(tracks: tracks), !fixes.isEmpty else { return }
        for fix in fixes { coverFixes[fix.id] = fix.coverUrl }
    }

    /// Dernier envoi « j'aime » de chaque titre (voir `setLiked`).
    @ObservationIgnored private var likeTasks: [Int64: Task<Void, Never>] = [:]
    /// Numéro du dernier appui sur « j'aime » de chaque titre : un envoi refusé ne défait l'affichage que s'il est le
    /// dernier (sinon il effaçait le choix plus récent, pourtant bien enregistré chez Deezer).
    @ObservationIgnored private var likeGeneration: [Int64: Int] = [:]

    func setLiked(_ track: Track, _ liked: Bool) {
        guard let core else { return }
        // Tout de suite à l'écran ; annulé si Deezer refuse.
        if liked { lovedIds.insert(track.id) } else { lovedIds.remove(track.id) }
        details[.loved] = nil // la page Titres aimés sera rechargée
        let gen = profileGeneration
        // Appuis rapides (j'aime puis plus) : envoyés à Deezer l'un après l'autre, dans l'ordre, pour que le dernier
        // choix soit bien celui gardé.
        let previous = likeTasks[track.id]
        likeGeneration[track.id, default: 0] += 1
        let mine = likeGeneration[track.id] ?? 0
        likeTasks[track.id] = Task {
            await previous?.value
            do {
                try await core.setLiked(id: track.id, liked: liked)
                // Titres aimés téléchargés : seul ce titre est ajouté ou retiré (avant, toute la liste était rechargée).
                // Titres aimés téléchargés du profil ouvert (le cœur garde ceux de chaque profil à part) : seulement si
                // le profil n'a pas changé entre-temps.
                if gen == profileGeneration {
                    if liked {
                        addDownloadedTrack(kind: "loved", id: 0, track: track)
                    } else {
                        removeDownloadedTrack(kind: "loved", id: 0, trackId: track.id)
                    }
                }
            } catch {
                // Profil changé entre-temps : ses cœurs à lui ne sont pas touchés.
                guard gen == profileGeneration else { return }
                if liked { lovedIds.remove(track.id) } else { lovedIds.insert(track.id) }
                showToast(describe(error), seconds: 4)
            }
        }
    }

    // MARK: Lecture

    func play(_ tracks: [Track], at index: Int) {
        guard tracks.indices.contains(index) else { return }
        // Titres pas encore sortis ou retirés : hors de la file (Deezer les refuse, la lecture s'arrêtait dessus). Le titre
        // demandé lui-même indisponible (« Lecture » d'un album dont le 1er titre n'est pas sorti) : le suivant lisible.
        if tracks.contains(where: \.unavailable) {
            let order = Array(tracks[index...]) + Array(tracks[..<index])
            guard let start = order.first(where: { !$0.unavailable }) else {
                showToast(tr("Pas encore disponible sur Deezer"))
                return
            }
            let playable = tracks.filter { !$0.unavailable }
            guard let at = playable.firstIndex(where: { $0.id == start.id }) else { return }
            play(playable, at: at)
            return
        }
        pendingRestore = nil
        activateOutput()
        current = tracks[index]
        isFlow = false
        startLoading()
        attempt { try $0.play(ids: tracks.map(\.id), index: UInt32(index)) }
    }

    func playFlow() {
        guard let core else { return }
        pendingRestore = nil
        activateOutput()
        isFlow = true
        startLoading()
        Task {
            do { try await core.playFlow() } catch { loading = false; showToast(describe(error), seconds: 4) }
        }
    }

    /// Lance le mix inspiré d'un titre (« Mixes inspirés par » de l'accueil).
    func playTrackMix(_ id: UInt64) {
        guard let core else { return }
        pendingRestore = nil
        activateOutput()
        isFlow = false
        startLoading()
        Task {
            do { try await core.playTrackMix(id: Int64(id)) } catch { loading = false; showToast(describe(error), seconds: 4) }
        }
    }

    /// Décidé d'après l'état réel du moteur : un appui (app, écran verrouillé, écouteurs) fait toujours ce qu'on attend,
    /// même si l'affichage a une fraction de seconde de retard.
    func toggle() {
        let playing = core?.status().playing ?? status.playing
        if playing { pause() } else { resume() }
    }

    /// Session audio activée avant de lancer un titre ; sortie rouverte si iOS l'a arrêtée (appel terminé sans
    /// reprise) : sans ça, le nouveau titre pouvait rester muet.
    private func activateOutput() {
        resumePolicy.userDecided()
        AudioSession.activate()
        guard needsReopen, let core else { return }
        needsReopen = false
        core.audioResumed(shouldResume: false)
    }

    func resume() {
        resumePolicy.userDecided() // appui de l'utilisateur : il décide, plus de reprise automatique en attente
        if let last = pendingRestore {
            restoreLastSession(last, index: queueIndex, position: status.positionMs)
            return
        }
        AudioSession.activate()
        if needsReopen, let core {
            needsReopen = false
            core.audioResumed(shouldResume: true)
        } else {
            attempt { try $0.resume() }
        }
        refreshStatus()
    }

    /// Le moteur audio d'iOS a refusé de redémarrer : pause côté cœur, sans effacer les reprises automatiques prévues
    /// (ce n'est pas un choix de l'utilisateur). Un appui sur lecture relance le moteur.
    func outputGaveUp() {
        attempt { try $0.pause() }
        refreshStatus()
    }

    func pause() {
        resumePolicy.userDecided()
        defer { saveLastSession() } // position de la pause gardée pour la reprise au lancement
        attempt { try $0.pause() }
        refreshStatus()
    }
    func next() { skip(1) }

    func previous() {
        // Dernière écoute pas encore relancée (moteur vide) : retour au début du titre gardé, pas un appel au cœur.
        if let last = pendingRestore, position(at: Date()) > 3 || queueIndex == 0 {
            restoreLastSession(last, index: queueIndex, position: 0)
            return
        }
        // Plus de 3 s de lecture : retour au début du titre (le cœur s'en charge).
        if skipTarget == nil, position(at: Date()) > 3 { attempt { try $0.previous() }; return }
        skip(-1)
    }

    /// Titre visé pendant une rafale d'appuis sur suivant / précédent, et dernier envoyé au cœur.
    @ObservationIgnored private var skipTarget: Int?
    @ObservationIgnored private var sentTarget: Int?
    @ObservationIgnored private var skipWindow: Task<Void, Never>?

    /// Le premier appui part tout de suite ; les suivants (dans les 180 ms) sont regroupés en un seul saut
    /// vers le bon titre, au lieu de faire charger au cœur chaque titre intermédiaire.
    private func skip(_ delta: Int) {
        if let last = pendingRestore {
            if queue.indices.contains(queueIndex + delta) { restoreLastSession(last, index: queueIndex + delta, position: 0) }
            return
        }
        let target = (skipTarget ?? awaitedIndex ?? queueIndex) + delta
        guard queue.indices.contains(target) else {
            // Bout de la file (Flow, répétition) : le cœur décide, une fois par rafale.
            if skipTarget == nil { attempt { try delta > 0 ? $0.next() : $0.previous() } }
            return
        }
        activateOutput()
        current = queue[target]
        shownIndex = target
        startLoading()
        NowPlaying.update(track: current, status: Status(playing: false, positionMs: 0, durationMs: 0))
        if skipWindow == nil {
            attempt { try $0.queuePlay(index: UInt32(target)) }
            sentTarget = target
            awaiting = (target, Date())
        }
        skipTarget = target
        skipWindow?.cancel()
        skipWindow = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            if let t = skipTarget, t != sentTarget {
                attempt { try $0.queuePlay(index: UInt32(t)) }
                awaiting = (t, Date())
            }
            skipTarget = nil
            sentTarget = nil
            skipWindow = nil
        }
    }

    /// Mêmes informations affichées (le cœur renvoie souvent le même titre plusieurs fois à chaque changement).
    private static func sameTrack(_ a: Track, _ b: Track) -> Bool {
        a.id == b.id && a.title == b.title && a.artist == b.artist && a.album == b.album && a.durationS == b.durationS
            && a.coverUrl == b.coverUrl && a.quality == b.quality && a.artistId == b.artistId && a.albumId == b.albumId
            && a.artists.count == b.artists.count
    }

    /// Mise à jour d'un seul titre de la file (artistes complétés, pochette réparée) : remplacé là où il apparaît.
    private func updateQueued(_ track: Track) {
        for i in queue.indices where queue[i].id == track.id && !Self.sameTrack(queue[i], track) { queue[i] = track }
    }

    /// Titre demandé au cœur et pas encore confirmé par lui (sur réseau lent, il le résout avant de répondre). Un nouvel
    /// appui sur « suivant » part de lui, pas de l'ancien titre : avant, le 2e appui redemandait le même titre.
    /// Oublié au bout de 20 s (titre impossible à charger : le cœur ne le confirmera jamais).
    @ObservationIgnored private var awaiting: (index: Int, at: Date)?
    private var awaitedIndex: Int? {
        guard let a = awaiting, Date().timeIntervalSince(a.at) < 20 else { return nil }
        return a.index
    }

    func seek(seconds: Double) {
        let ms = UInt64(max(0, seconds) * 1000)
        // Dernière écoute pas encore relancée : la position choisie servira à la reprise.
        if pendingRestore == nil { attempt { try $0.seek(ms: ms) } }
        // Le curseur reste là où on l'a lâché, sans attendre le moteur.
        status = Status(playing: status.playing, positionMs: ms, durationMs: status.durationMs)
        statusAt = Date()
    }

    func queueAdd(_ tracks: [Track], next: Bool) {
        attempt { try $0.queueAdd(ids: tracks.map(\.id), next: next) }
        showToast(next ? tr("Lu juste après") : tr("Ajouté à la file"))
    }

    /// Oublie les copies hors ligne gardées en mémoire (session rouverte, réseau revenu).
    private func forgetOfflineDetails() {
        let stale = details.filter { $0.value.offline }.map(\.key)
        guard !stale.isEmpty else { return }
        for route in stale { details[route] = nil }
        detailOrder.removeAll { stale.contains($0) }
    }

    /// Oublie la page gardée en mémoire d'une playlist / d'un album, quel que soit le titre sous lequel elle a été ouverte.
    private func forgetDetail(kind: String, id: UInt64) {
        let stale = details.keys.filter {
            if case .detail(let k, let i, _) = $0 { return k == kind && i == id }
            return false
        }
        for route in stale { details[route] = nil }
        detailOrder.removeAll { stale.contains($0) }
    }

    private func trimMemory() {
        details = [:]
        detailOrder = []
        lyricsCache = [:]
    }

    /// Ouvre une page depuis le lecteur plein écran (qui se ferme), dans l'onglet affiché.
    func navigate(_ route: Route) {
        showFullPlayer = false
        requestedRoute = route
    }

    func showToast(_ text: String, seconds: Double = 2) {
        toast = text
        toastGeneration += 1
        let generation = toastGeneration
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if toastGeneration == generation { toast = nil }
        }
    }

    /// Playlists où l'on peut ajouter un titre (les siennes, hors Coups de cœur).
    var ownedPlaylists: [Card] { (library[0] ?? []).filter { $0.kind == "playlist" && $0.owned } }

    /// Image de « Coups de cœur » choisie sur Deezer (nil = cœur par défaut).
    var lovedCover: String? {
        customCovers["loved"]
            ?? lovedCard?.coverUrl
            ?? (library[0] ?? []).first { $0.kind == "loved" }?.coverUrl
            ?? home?.lazy.flatMap(\.items).first { $0.kind == "loved" }?.coverUrl
    }

    /// Fiche « Coups de cœur » demandée directement à Deezer (son image ne dépend pas de la liste des playlists).
    private(set) var lovedCard: Card?

    private func refreshLovedCard() async {
        guard let core else { return }
        let gen = profileGeneration
        if let card = try? await core.lovedCard(), gen == profileGeneration { lovedCard = card }
    }

    /// Pochettes perso (clé : `CustomCovers.key`, valeur : adresse du fichier sur le téléphone).
    private(set) var customCovers: [String: String] = CustomCovers.load()
    /// Élément dont on choisit la pochette (sélecteur de photos ouvert).
    var coverTarget: Card?
    var pickingCover = false

    /// Pochette à afficher : la perso si elle existe, sinon celle de Deezer.
    func coverURL(_ card: Card) -> String? {
        if card.kind == "loved" { return lovedCover }
        return CustomCovers.key(card).flatMap { customCovers[$0] } ?? card.coverUrl
    }

    func coverURL(kind: String, id: UInt64, fallback: String?) -> String? {
        if kind == "loved" { return lovedCover ?? fallback }
        return CustomCovers.key(kind: kind, id: id).flatMap { customCovers[$0] } ?? fallback
    }

    func hasCustomCover(_ card: Card) -> Bool { CustomCovers.key(card).map { customCovers[$0] != nil } ?? false }

    func chooseCover(for card: Card) {
        coverTarget = card
        pickingCover = true
    }

    /// Image choisie : recadrée et enregistrée en tâche de fond, puis affichée partout.
    func setCustomCover(_ card: Card, data: Data) async {
        guard let key = CustomCovers.key(card) else { return }
        let url = await Task.detached(priority: .userInitiated) { CustomCovers.save(data, key: key) }.value
        guard let url else { showToast(tr("Image illisible : choisis une autre photo."), seconds: 4); return }
        customCovers[key] = url
        CustomCovers.store(customCovers)
        showToast(tr("Pochette changée sur ce téléphone"))
    }

    func removeCustomCover(_ card: Card) {
        guard let key = CustomCovers.key(card) else { return }
        customCovers[key] = nil
        CustomCovers.store(customCovers)
        CustomCovers.remove(key: key)
        showToast(tr("Pochette d'origine rétablie"))
    }

    func addToPlaylist(_ playlist: Card, _ track: Track) {
        guard let core else { return }
        Task {
            do {
                try await core.playlistAdd(playlistId: playlist.id, trackId: track.id)
                forgetDetail(kind: "playlist", id: playlist.id) // rechargée à la prochaine visite
                // Playlist téléchargée : seul le titre ajouté est téléchargé, sans recharger toute la playlist.
                addDownloadedTrack(kind: "playlist", id: playlist.id, track: track)
                showToast(tr("Ajouté à « %@ »", playlist.title))
            } catch { showToast(describe(error), seconds: 4) }
        }
    }

    /// Retire un titre d'une de ses playlists. La page l'a déjà enlevé de l'écran ; `false` si Deezer refuse
    /// (la page le remet). Les pages gardées en mémoire suivent, sans rechargement.
    func removeFromPlaylist(_ playlistId: UInt64, _ track: Track) async -> Bool {
        guard let core else { return false }
        do {
            try await core.playlistRemove(playlistId: playlistId, trackId: track.id)
            removeDownloadedTrack(kind: "playlist", id: playlistId, trackId: track.id)
            for route in details.keys {
                if case .detail("playlist", playlistId, _) = route { details[route]?.tracks.removeAll { $0.id == track.id } }
            }
            showToast(tr("Retiré de la playlist"))
            return true
        } catch {
            showToast(describe(error), seconds: 4)
            return false
        }
    }

    func queuePlay(_ index: Int) {
        if let last = pendingRestore {
            restoreLastSession(last, index: index, position: 0)
            return
        }
        activateOutput()
        if queue.indices.contains(index) { current = queue[index]; shownIndex = index }
        startLoading()
        attempt { try $0.queuePlay(index: UInt32(index)) }
    }

    /// Indicateur jusqu'au signal « son lancé » du cœur ; retiré de toute façon après 20 s (réseau coupé...).
    @ObservationIgnored private var loadingTimeout: Task<Void, Never>?
    private func startLoading() {
        loading = true
        // Une rafale de suivant / précédent ne laisse pas une tâche en attente par appui.
        loadingTimeout?.cancel()
        loadingTimeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            loading = false
        }
    }
    func queueRemove(_ index: Int) { attempt { try $0.queueRemove(index: UInt32(index)) } }

    /// `to` : position finale du titre (déjà corrigée du décalage de SwiftUI).
    func queueMove(from: Int, to: Int) { attempt { try $0.queueMove(from: UInt32(from), to: UInt32(to)) } }

    func toggleShuffle() {
        shuffle.toggle()
        let on = shuffle
        attempt { try $0.setShuffle(on: on) }
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
        let mode = repeatMode
        attempt { try $0.setRepeat(mode: mode) }
        NowPlaying.setSkips(next: hasNext, previous: hasPrevious)
    }

    /// Position courante, calculée sans appel à Rust.
    func position(at date: Date) -> Double {
        if loading { return 0 }
        let base = Double(status.positionMs) / 1000
        let pos = status.playing ? base + date.timeIntervalSince(statusAt) : base
        let duration = Double(status.durationMs) / 1000
        return duration > 0 ? min(pos, duration) : pos
    }

    /// Pochettes des 2 titres suivants préparées à l'avance : au changement de titre, elles s'affichent tout de suite.
    private func prefetchCovers() {
        let next = queue.dropFirst(queueIndex + 1).prefix(2).compactMap(\.coverUrl)
        let previous = queueIndex > 0 && queue.indices.contains(queueIndex - 1) ? queue[queueIndex - 1].coverUrl : nil
        let around = Array(next) + [previous].compactMap { $0 }
        guard !around.isEmpty else { return }
        // En arrière-plan, seule la grande pochette du titre suivant sert (écran verrouillé) : pas de vignettes.
        let background = UIApplication.shared.applicationState == .background
        if !background { CoverLoader.shared.prefetch(around, pixels: 150) } // mini-lecteur et listes (suivants et précédent)
        // Le titre suivant en grand : écran verrouillé et lecteur plein écran nets dès le changement de titre.
        if let first = next.first { CoverLoader.shared.prefetch([first], pixels: 1000) }
        if showFullPlayer, !background, let previous { CoverLoader.shared.prefetch([previous], pixels: 1000) }
    }

    /// Vérification unique, 1 s après le démarrage d'un titre (le moment où un état de transition « en pause, 0:00 »
    /// peut rester affiché) : l'état affiché dans l'app et sur l'écran verrouillé est comparé à celui du moteur et
    /// corrigé s'il s'en écarte. Aucun réveil régulier : le reste du temps, ce sont les événements du moteur qui
    /// tiennent l'affichage à jour (et une relecture au verrouillage, au Centre de contrôle et au retour dans l'app).
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?

    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.checkStatus()
        }
    }

    private func checkStatus() {
        guard let core, current != nil, !loading, pendingRestore == nil else { return }
        let truth = core.status()
        let shownMs = position(at: Date()) * 1000
        let drift = abs(Double(truth.positionMs) - shownMs)
        guard truth.playing != status.playing || truth.durationMs != status.durationMs || drift > 2000 else { return }
        status = truth
        statusAt = Date()
        NowPlaying.update(track: current, status: status)
    }

    private func refreshStatus() {
        syncStatus()
        NowPlaying.update(track: current, status: status)
    }

    /// Lit l'état du moteur pour un affichage immédiat, et demande au cœur de renvoyer l'état réel juste après :
    /// une lecture faite pendant un chargement (état de transition) est ainsi corrigée aussitôt, dans l'app comme
    /// sur l'écran verrouillé, au lieu de rester affichée.
    private func syncStatus() {
        // Dernière écoute affichée mais pas encore relancée : le moteur ne joue rien, son état (0:00) ne doit pas
        // remplacer la position gardée.
        guard let core, pendingRestore == nil else { return }
        status = core.status()
        statusAt = Date()
        core.refreshState()
    }

    /// Commande de lecture : un refus s'affiche en bulle discrète, pas en alerte à fermer.
    private func attempt(_ body: (Core) throws -> Void) {
        guard let core else { return }
        do { try body(core) } catch { showToast(describe(error), seconds: 4) }
    }

    func describe(_ error: Error) -> String {
        switch error as? CoreError {
        case .Api(let m), .Keychain(let m): return m
        case .Player: return tr("Lecteur indisponible.")
        case .UnknownTrack: return tr("Titre inconnu : recharge la page.")
        case nil: return error.localizedDescription
        }
    }

    // MARK: Événements du cœur

    func handle(_ event: Event) {
        // Dernière écoute pas encore relancée : le premier état envoyé par le moteur (« en pause, 0:00 ») est ignoré,
        // sinon la reprise partirait du début.
        if pendingRestore != nil, case .state = event { return }
        switch event {
        case .track(var track):
            // Même titre que celui déjà affiché (passage au suivant) : sa pochette reste la même adresse.
            // Un titre téléchargé arrive d'abord avec son image enregistrée puis avec celle de Deezer : changer
            // d'adresse relançait le fondu du fond du lecteur en plein milieu (saut d'image).
            // Deux adresses Deezer différentes, en revanche : pochette réparée par le cœur (l'ancienne n'existait plus).
            if let shown = current, shown.id == track.id, let cover = shown.coverUrl,
               !(cover.hasPrefix("http") && track.coverUrl?.hasPrefix("http") == true) { track.coverUrl = cover }
            if current.map({ !Self.sameTrack($0, track) }) ?? true { current = track }
            // Aussi pour les enchaînements automatiques (fin de titre), qui n'ont pas de signal « son lancé ».
            scheduleCheck()
            // Nouveau titre : état réel du moteur (lecture, position, durée) relu tout de suite pour l'écran verrouillé.
            syncStatus()
        case .started:
            loading = false
            syncStatus()
            scheduleCheck()
        case .state(let s):
            status = s
            statusAt = Date()
        case .error(let m):
            // Titre demandé impossible à charger : le cœur reste sur l'ancien, l'affichage aussi.
            awaiting = nil
            // Le titre demandé n'a pas pu être chargé : le cœur revient au titre qui joue encore (événements
            // QueueIndex et Track) ; on abandonne aussi la rafale de suivant / précédent en cours.
            loading = false
            skipWindow?.cancel()
            skipWindow = nil
            skipTarget = nil
            sentTarget = nil
            syncStatus()
            // Message court du cœur (déjà traduit) : bulle discrète, pas une alerte à fermer.
            showToast(m, seconds: 4)
        case .stopped:
            loading = false
            syncStatus()
        case .closed:
            loading = false
            LastSession.clear()
            current = nil
            queue = []
            queueIndex = 0
            isFlow = false
            status = Status(playing: false, positionMs: 0, durationMs: 0)
        case .queue(let tracks, let index):
            queue = tracks
            queueIndex = Int(index)
            // Nouvelle file (autre album, playlist…) : un titre demandé dans l'ancienne n'est plus attendu (sinon le
            // « suivant » d'après partait de son index, dans la nouvelle file, pendant 20 s).
            awaiting = nil
        case .queueIndex(let index):
            if queueIndex != Int(index) { queueIndex = Int(index) }
            if awaiting?.index == Int(index) { awaiting = nil } // titre demandé confirmé
            // Dernière écoute gardée à chaque changement de titre : iOS peut fermer l'app suspendue sans prévenir
            // (et ne prévient pas non plus quand CarPlay l'a lancée en arrière-plan).
            saveLastSession()
        case .queueInsert(let at, let tracks, let index):
            queue.insert(contentsOf: tracks, at: min(Int(at), queue.count))
            queueIndex = Int(index)
        case .queueRemove(let at, let index):
            if queue.indices.contains(Int(at)) { queue.remove(at: Int(at)) }
            queueIndex = Int(index)
        case .queueUpdate(let track):
            updateQueued(track)
        case .queueMove(let from, let to, let index):
            if queue.indices.contains(Int(from)), queue.indices.contains(Int(to)) {
                queue.insert(queue.remove(at: Int(from)), at: Int(to))
            }
            queueIndex = Int(index)
        case .downloadsChanged:
            refreshDownloads()
        }
        switch event {
        case .track, .started, .state, .stopped, .closed: NowPlaying.update(track: current, status: status)
        default: break
        }
        switch event {
        case .track, .queue, .queueIndex: prefetchCovers()
        default: break
        }
        // Comparé avant d'écrire : avec @Observable, même une valeur identique redessine tout ce qui la lit
        // (carrousels du mini-lecteur et du grand lecteur, file d'attente, CarPlay).
        // Titre demandé pas encore confirmé : l'affichage reste dessus (le cœur peut d'abord renvoyer l'ancien index).
        if skipTarget == nil, awaitedIndex == nil, shownIndex != queueIndex { shownIndex = queueIndex }
        NowPlaying.setSkips(next: hasNext, previous: hasPrevious)
    }

    // MARK: Session audio : interruptions et sortie

    /// Sorties « dans les oreilles » : une pause à leur retrait est reprise à leur retour.
    nonisolated private static let earPorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in
                guard let self, let core = self.core else { return }
                switch type {
                case .began:
                    // « En train de démarrer » compte comme jouer : un titre lancé juste avant l'appel repart après.
                    self.resumePolicy.interruptionBegan(playing: core.status().playing || self.loading)
                    // Comme les autres apps de musique : pause, et l'app reste sur l'écran verrouillé.
                    AudioSession.invalidate()
                    core.audioInterrupted()
                case .ended:
                    if self.resumePolicy.interruptionEnded(shouldResume: options.contains(.shouldResume)) {
                        AudioSession.activate()
                        core.audioResumed(shouldResume: true)
                    } else {
                        // Pas de reprise : on ne reprend pas la main sur le son des autres apps.
                        self.needsReopen = true
                    }
                default:
                    break
                }
                self.refreshStatus()
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            let previous = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.first { Self.earPorts.contains($0.portType) }?.uid
            let current = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable {
                    // Écouteurs débranchés, AirPods retirés des oreilles : pause (jamais de bascule sur le haut-parleur),
                    // et reprise s'ils reviennent.
                    let wasPlaying = self.core?.status().playing ?? false
                    self.pause()
                    self.resumePolicy.earbudsRemoved(uid: previous, wasPlaying: wasPlaying)
                } else if !self.resumePolicy.interrupted, self.resumePolicy.earbudsReturned(currentOutputs: current) {
                    // Les mêmes écouteurs sont revenus (AirPods remis) : la musique reprend, comme dans les autres apps.
                    self.resume()
                }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                AudioSession.invalidate()
                AudioSession.configure()
                self?.needsReopen = true
                self?.pause()
            }
        }
    }
}

/// Élément du haut de l'accueil, déplaçable par appui long.
enum HomeItem: Hashable {
    case flow, loved
    case pin(Pin)

    var id: String {
        switch self {
        case .flow: "flow"
        case .loved: "loved"
        case .pin(let p): "pin:\(p.kind):\(p.id):\(p.key)"
        }
    }
}
