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
    private(set) var current: Track? {
        didSet {
            if (current != nil) != hasTrack { hasTrack = current != nil }
            syncMiniShown()
        }
    }
    /// Un titre est affiché. Lu par la barre d'onglets et le mini-lecteur à la place de `current` : lire `current`
    /// redessinait les onglets (et leurs pages) à chaque changement de titre.
    private(set) var hasTrack = false
    private(set) var status = Status(playing: false, positionMs: 0, durationMs: 0)
    /// Instant où `status` a été reçu : la position affichée est extrapolée à partir de là, sans interroger Rust.
    private(set) var statusAt = Date()
    /// Titre demandé, son pas encore arrivé (affiché tout de suite pour que l'appui réponde immédiatement).
    private(set) var loading = false {
        didSet { syncMiniShown() }
    }
    /// Mini-lecteur à montrer (un titre, ou un chargement). Ne change que quand sa valeur change : avant, les onglets et
    /// chaque page lisaient `hasTrack || loading`, et `loading`, qui bascule à chaque lecture demandée (et même quand il
    /// garde sa valeur), redessinait la racine de l'app deux fois par appui sur suivant, précédent ou lecture.
    private(set) var miniShown = false
    private func syncMiniShown() {
        let shown = hasTrack || loading
        if shown != miniShown { miniShown = shown }
    }
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
    /// Page Téléchargements demandée depuis les Réglages : ouverte dans la Bibliothèque (voir `MainTabs`).
    var openDownloadsPage = 0
    /// Section de la Bibliothèque à ouvrir dans l'onglet affiché (voir `TabStack`).
    var requestedSection: LibrarySection?
    /// Pages déjà chargées : affichées tout de suite en revenant dessus (tirer vers le bas pour actualiser).
    private(set) var home: [Shelf]?
    /// Change à chaque nouvelle file (autre album, playlist, Flow…).
    @ObservationIgnored private(set) var queueGeneration = 0
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
    /// Modifications des téléchargements faites hors du fil principal, l'une après l'autre (aimer puis retirer vite :
    /// toujours dans cet ordre).
    @ObservationIgnored private var downloadEdits: Task<Void, Never>?
    @ObservationIgnored private var bytesTask: Task<Void, Never>?
    /// Taille redemandée pendant un parcours : refaite à la fin de celui-ci.
    @ObservationIgnored private var bytesAgain = false
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
        BackgroundDownloadManager.shared.networkChanged(up: signature != "none", newNetwork: networkSignature != signature)
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
            // Accueil et playlists pas encore chargés (échec, coupure) : redemandés maintenant.
            if sessionReady {
                Task {
                    async let h: Void = loadHome(force: false)
                    async let p: Void = loadLibrary(0, force: false)
                    _ = await (h, p)
                }
            }
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
        guard core != nil, loggedIn == true, !loggingOut, !detail.tracks.isEmpty else { return }
        // Dans la file des modifications : passe après une suppression de cette collection demandée juste avant.
        editDownloads {
            // Déconnexion commencée entre-temps : avant, la collection était enregistrée et téléchargée pour le compte suivant.
            guard self.loggedIn == true, !self.loggingOut else { return }
            do {
                let missing = try await self.storeDownloadCollection(detail)
                if missing.isEmpty {
                    self.showToast(tr("%@ est disponible hors ligne", detail.title))
                } else {
                    self.download(missing)
                }
            } catch { self.message = self.describe(error) }
        }
    }

    /// `refresh` : listes relues tout de suite (action de l'utilisateur) ; sinon hors du thread principal (synchro au
    /// lancement : une relecture complète par collection, avec un contrôle de fichier par titre téléchargé).
    private func storeDownloadCollection(_ detail: Detail, refresh: Bool = true) async throws -> [Track] {
        guard let core else { return [] }
        let removed = try await core.downloadCollection(detail: detail)
        // Titres sortis de la collection : leur téléchargement en attente ne finit plus en titre téléchargé seul.
        if !removed.isEmpty { BackgroundDownloadManager.shared.cancel(removed) }
        // Relues hors du fil principal : sur le fil principal, l'appui sur « Télécharger » figeait l'app avec une grosse
        // bibliothèque hors ligne (toutes les fiches converties, un contrôle de fichier par titre).
        if refresh { await refreshDownloadsInBackground() } else { scheduleDownloadsRefresh() }
        // Titres pas encore sortis ou retirés : Deezer refuse de les télécharger (ils échouaient à chaque lancement).
        return detail.tracks.filter { !downloadedIds.contains($0.id) && !$0.unavailable }
    }

    private func syncDownloadedCollection(kind: String, id: UInt64) async {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return }
        let gen = profileGeneration
        let fresh: Detail
        do {
            fresh = kind == "loved"
                ? try await core.lovedDetail()
                : try await core.openDetail(kind: kind, id: id)
        } catch { return }
        // Deezer injoignable : le cœur a renvoyé la copie hors ligne, qu'il ne faut pas réenregistrer
        // (les titres pas encore téléchargés disparaîtraient de la collection).
        guard !fresh.offline else { return }
        // Dans la file des modifications, et relue là : une suppression demandée pendant la requête passe avant (avant,
        // la collection supprimée était recréée puis retéléchargée en entier).
        await editDownloads {
            // Profil changé pendant la requête (la réponse peut être celle de l'autre profil), ou collection retirée.
            guard gen == self.profileGeneration, self.downloadedCollection(kind: kind, id: id) != nil,
                  let missing = try? await self.storeDownloadCollection(fresh, refresh: false) else { return }
            // Sauf ceux annulés ou supprimés à la main (voir `skippedDownloads`).
            let new = missing.filter { self.downloadStates[$0.id] == nil && !self.skippedDownloads.contains($0.id) }
            if !new.isEmpty { self.download(new) }
        }.value
    }

    /// Une collection qui échoue (playlist supprimée sur Deezer…) n'empêche plus la synchro des suivantes.
    private func syncDownloadedCollections() async {
        let saved = downloadCollections
        for collection in saved {
            await syncDownloadedCollection(kind: collection.kind, id: collection.id)
        }
    }

    /// Ajoute un titre à une collection téléchargée et lance son téléchargement, sans recharger toute la collection.
    /// Hors du fil principal : avec des milliers de titres téléchargés, l'écriture sur le disque et la relecture des
    /// listes figeaient l'écran à chaque cœur (0,05 à 0,3 s).
    private func addDownloadedTrack(kind: String, id: UInt64, track: Track) {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return }
        let (did, tid) = (Self.downloadId(kind: kind, id: id), track.id)
        editDownloads {
            do {
                let added = try await Task.detached(priority: .userInitiated) { try core.addDownloadTrackToCollection(kind: kind, id: did, trackId: tid) }.value
                await self.refreshDownloadsInBackground()
                // Collection retirée entre-temps : le titre n'y est pas, il ne doit pas devenir un téléchargement seul.
                guard added else { return }
                if !self.downloadedIds.contains(tid), self.downloadStates[tid] == nil { self.download([track]) }
            } catch {
                self.showToast(tr("La copie hors ligne n'a pas pu être actualisée"), seconds: 4)
            }
        }
    }

    private func removeDownloadedTrack(kind: String, id: UInt64, trackId: Int64) {
        guard let core, downloadedCollection(kind: kind, id: id) != nil else { return }
        let did = Self.downloadId(kind: kind, id: id)
        editDownloads {
            do {
                let removed = try await Task.detached(priority: .userInitiated) {
                    try core.removeDownloadTrackFromCollection(kind: kind, id: did, trackId: trackId)
                }.value
                if !removed.isEmpty { BackgroundDownloadManager.shared.cancel(removed) }
                await self.refreshDownloadsInBackground()
            } catch {
                self.showToast(tr("La copie hors ligne n'a pas pu être actualisée"), seconds: 4)
            }
        }
    }

    /// Lance une modification des téléchargements après celles en cours.
    @discardableResult
    private func editDownloads(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = downloadEdits
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        downloadEdits = task
        return task
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
        showToast(tr("Préparation du téléchargement…"), seconds: 10)
        Task {
            defer { preparingDownloads.remove(key) }
            if let detail = await detail(route, force: false), !detail.offline {
                download(detail)
            } else {
                showToast(tr("Impossible de charger cette collection"), seconds: 4)
            }
        }
    }

    /// Titres dont le téléchargement a été annulé ou supprimé à la main : la synchro des playlists et albums téléchargés
    /// (à chaque ouverture de session) ne les relance pas. Un téléchargement redemandé par l'utilisateur les en retire.
    @ObservationIgnored private var skippedDownloads: Set<Int64> =
        Set((UserDefaults.standard.array(forKey: "skippedDownloads") as? [NSNumber] ?? []).map(\.int64Value))

    private func skipDownloads(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        skippedDownloads.formUnion(ids)
        saveSkippedDownloads()
    }

    private func saveSkippedDownloads() {
        if skippedDownloads.isEmpty {
            UserDefaults.standard.removeObject(forKey: "skippedDownloads")
        } else {
            UserDefaults.standard.set(skippedDownloads.map { NSNumber(value: $0) }, forKey: "skippedDownloads")
        }
    }

    func download(_ tracks: [Track]) {
        // Compte fermé (synchro encore en route pendant la déconnexion) : rien n'est ajouté pour le compte suivant.
        guard core != nil, loggedIn == true, !loggingOut, !tracks.isEmpty else { return }
        // Redemandés par l'utilisateur : de nouveau suivis par la synchro.
        let ids = tracks.map(\.id)
        if !skippedDownloads.isDisjoint(with: ids) {
            skippedDownloads.subtract(ids)
            saveSkippedDownloads()
        }
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
        showToast(count == 0 ? tr("Déjà téléchargé ou en cours") : count == 1 ? tr("1 téléchargement ajouté") : tr("%@ téléchargements ajoutés", "\(count)"))
    }

    /// Ordre de la file de téléchargement (pour l'écran Téléchargements).
    var downloadQueueOrder: [Int64] { BackgroundDownloadManager.shared.queueOrder }

    func cancelDownload(_ id: Int64) {
        skipDownloads([id]) // annulé à la main : pas relancé par la synchro
        BackgroundDownloadManager.shared.cancel(id)
    }

    func cancelAllDownloads() {
        skipDownloads(BackgroundDownloadManager.shared.queueOrder) // « Tout arrêter » : rien n'est relancé tout seul
        BackgroundDownloadManager.shared.stopAll()
        showToast(tr("Téléchargements arrêtés"))
    }

    /// Retire de la liste les téléchargements en échec.
    func clearFailedDownloads() {
        skipDownloads(downloadStates.filter { $0.value.state == .failed }.map(\.key)) // retirés à la main
        BackgroundDownloadManager.shared.clearFailed()
    }

    func removeDownload(_ id: Int64) {
        guard let core else { return }
        skipDownloads([id]) // supprimé à la main : pas retéléchargé par la synchro de sa playlist ou de son album
        BackgroundDownloadManager.shared.cancel(id)
        // Hors du fil principal (fichiers supprimés, liste réécrite sur le disque) : plus de gel.
        editDownloads {
            do {
                try await Task.detached(priority: .userInitiated) { try core.removeDownload(id: id) }.value
                self.forgetOfflineDetails()
                await self.refreshDownloadsInBackground()
            } catch { self.message = self.describe(error) }
        }
    }

    /// Fichiers supprimés hors du thread principal : des centaines de titres figeaient l'app quelques secondes.
    /// La tâche rendue finit une fois les fichiers supprimés et les listes relues.
    @discardableResult
    func removeDownloadCollection(_ collection: DownloadCollection) -> Task<Void, Never>? {
        guard let core else { return nil }
        let (kind, id) = (collection.kind, collection.id)
        // Dans la file des modifications : un titre aimé juste avant n'y est plus ajouté après coup.
        return editDownloads {
            do {
                let ids = try await Task.detached(priority: .userInitiated) { try core.removeDownloadCollection(kind: kind, id: id) }.value
                BackgroundDownloadManager.shared.cancel(ids)
                // Copies hors ligne gardées en mémoire : elles montraient encore la collection supprimée.
                self.forgetOfflineDetails()
                await self.refreshDownloadsInBackground()
                self.showToast(tr("%@ supprimé des téléchargements", collection.title))
            } catch { self.message = self.describe(error) }
        }
    }

    func clearDownloads() {
        guard let core else { return }
        BackgroundDownloadManager.shared.stopAll()
        editDownloads {
            do {
                // Tous les fichiers supprimés : hors du thread principal (l'app restait figée avec une grosse bibliothèque).
                try await Task.detached(priority: .userInitiated) { try core.clearDownloads() }.value
                self.downloadStates = [:]
                self.downloadTracks = [:]
                // Copies hors ligne gardées en mémoire : sans réseau, elles restaient servies et la lecture échouait.
                self.forgetOfflineDetails()
                await self.refreshDownloadsInBackground()
                self.showToast(tr("Téléchargements effacés"))
            } catch { self.message = self.describe(error) }
        }
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
        showToast(tr("La file de téléchargement n'a pas pu être enregistrée"), seconds: 4)
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
            // Libéré avant la lecture : un titre qui finit pendant celle-ci programme une nouvelle relecture (avant, il
            // était ignoré, et cette lecture plus ancienne le faisait disparaître de la liste).
            self?.downloadsRefreshTask = nil
            let lists = await Task.detached(priority: .utility) {
                (Set(core.downloadedIds()), core.standaloneDownloads(), core.downloadCollections())
            }.value
            guard !Task.isCancelled, let self, version == self.downloadsVersion else { return }
            if self.downloadedIds != lists.0 { self.downloadedIds = lists.0 }
            self.downloads = lists.1
            self.downloadCollections = lists.2
            self.refreshDownloadBytes()
            self.syncDownloadRows()
        }
    }

    /// Comme `refreshDownloads`, avec les listes lues hors du fil principal.
    func refreshDownloadsInBackground() async {
        guard let core else { return }
        cancelBackgroundDownloadsRefresh()
        let version = downloadsVersion
        let lists = await Task.detached(priority: .userInitiated) {
            (Set(core.downloadedIds()), core.standaloneDownloads(), core.downloadCollections())
        }.value
        guard version == downloadsVersion else { return } // une lecture plus récente a eu lieu entre-temps
        if downloadedIds != lists.0 { downloadedIds = lists.0 }
        downloads = lists.1
        downloadCollections = lists.2
        refreshDownloadBytes()
        syncDownloadRows()
    }

    private func cancelBackgroundDownloadsRefresh() {
        downloadsVersion &+= 1
        downloadsRefreshTask?.cancel()
        downloadsRefreshTask = nil
    }

    /// Taille occupée : calculée hors du thread principal (le cœur parcourt tout le dossier des téléchargements).
    /// Un seul parcours à la fois : demandé pendant un parcours, il est refait une fois celui-ci fini (avant, chaque
    /// titre terminé lançait un parcours complet de plus, en parallèle des précédents).
    private func refreshDownloadBytes() {
        guard let core else { return }
        guard bytesTask == nil else { bytesAgain = true; return }
        bytesTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) { core.downloadBytes() }.value
            guard !Task.isCancelled, let self else { return } // annulé (déconnexion) : `bytesTask` déjà remis à zéro
            self.bytesTask = nil
            if self.downloadBytes != bytes { self.downloadBytes = bytes }
            if self.bytesAgain {
                self.bytesAgain = false
                self.refreshDownloadBytes()
            }
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

    /// Nom de la page MP3, choisi sur ce téléphone (rien n'est envoyé à Deezer).
    private var customMp3Title = UserDefaults.standard.string(forKey: "mp3Title")
    var mp3Title: String { customMp3Title ?? "MP3" }
    /// Fenêtre « Renommer » de la page MP3 ouverte.
    var renamingMp3 = false

    func setMp3Title(_ name: String) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        customMp3Title = title.isEmpty || title == "MP3" ? nil : title
        if let customMp3Title {
            UserDefaults.standard.set(customMp3Title, forKey: "mp3Title")
        } else {
            UserDefaults.standard.removeObject(forKey: "mp3Title")
        }
    }

    /// Page MP3 vue comme une carte (menus de pochette et d'épingle).
    var mp3MenuCard: Card { Card(kind: "mp3", id: 0, title: mp3Title, subtitle: "", coverUrl: nil, owned: false, key: "") }

    /// Ordre des playlists de la Bibliothèque, choisi dans « Réorganiser les playlists » (identifiants des lignes).
    private(set) var libraryOrder: [String] = UserDefaults.standard.stringArray(forKey: "libraryOrder") ?? []

    func setLibraryOrder(_ ids: [String]) {
        // Lignes cachées en ce moment (Flow ou Titres aimés sur l'accueil, page MP3 épinglée) : gardées à leur place,
        // sinon elles revenaient en tête une fois de retour dans la Bibliothèque.
        var merged = ids
        for (i, id) in libraryOrder.enumerated() where !ids.contains(id) {
            merged.insert(id, at: min(i, merged.count))
        }
        libraryOrder = merged
        UserDefaults.standard.set(merged, forKey: "libraryOrder")
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
    /// Titres sans paroles et l'heure de la réponse : redemandés après 30 min (Deezer en ajoute ; l'app peut rester
    /// ouverte des jours). Avant : plus jamais redemandés tant que l'app restait ouverte.
    @ObservationIgnored private var noLyrics: [Int64: Date] = [:]

    /// Paroles du titre : Deezer d'abord. Seulement s'il n'en a pas (pas sur une erreur réseau) et si le réglage le permet,
    /// Genius en secours : texte simple, en ligne seulement, jamais gardé avec les titres téléchargés. `nil` : pas de
    /// paroles. Erreur si Deezer ne répond pas (réseau) : avant, elle passait pour « pas de paroles ».
    func lyrics(_ track: Track) async throws -> Lyrics? {
        let id = track.id
        if let hit = lyricsCache[id] { return hit }
        guard let core, noLyrics[id].map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true else { return nil }
        var found = try await core.lyrics(id: id)
        if found == nil, geniusLyrics, let genius = try await core.geniusLyrics(title: track.title, artist: track.artist) {
            found = Lyrics(synced: false, lines: genius.lines, copyright: tr("Paroles : Genius"))
        }
        guard let lyrics = found else {
            noLyrics[id] = Date()
            // Gardés 30 min seulement : les plus anciens sont oubliés plutôt que de s'accumuler.
            if noLyrics.count > 500 { noLyrics = noLyrics.filter { Date().timeIntervalSince($0.value) < 30 * 60 } }
            return nil
        }
        if lyricsCache.count >= 30 { lyricsCache.removeAll() }
        lyricsCache[id] = lyrics
        return lyrics
    }

    /// Réglage : paroles de secours sur Genius pour les titres sans paroles chez Deezer (activé par défaut).
    private(set) var geniusLyrics = UserDefaults.standard.object(forKey: "geniusLyrics") as? Bool ?? true

    func setGeniusLyrics(_ on: Bool) {
        geniusLyrics = on
        UserDefaults.standard.set(on, forKey: "geniusLyrics")
        // Titres « sans paroles » redemandés avec le nouveau réglage ; désactivé, les paroles de Genius ne s'affichent plus.
        lyricsCache = [:]
        noLyrics = [:]
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
        let before = beforePlay()
        pendingRestore = nil
        activateOutput()
        current = Track(id: id, title: entry.title ?? "", artist: entry.subtitle ?? "", album: "", durationS: 0, coverUrl: entry.coverUrl,
                        quality: nil, artistId: 0, albumId: 0, addedAt: nil, releaseDate: nil, artists: [])
        isFlow = false
        startLoading()
        Task {
            do {
                try await core.playById(id: id)
            } catch {
                playFailed(error, before: before, ifShowing: id)
            }
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
            // Au lancement, seulement ce qui sert tout de suite : la liste des titres téléchargés seuls (avec un regard sur
            // chaque fichier) est lue juste après, hors du fil principal (voir plus bas).
            downloadedIds = Set(core.downloadedIds())
            downloadCollections = core.downloadCollections()
        } catch {
            core = nil
            startError = tr("Démarrage impossible : %@", "\(error)")
        }
        message = startError
        events.player = self
        if core != nil { scheduleDownloadsRefresh() }
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
                // Téléchargements arrêtés faute de place : repris (de la place a pu être libérée dans Réglages).
                BackgroundDownloadManager.shared.resumeAfterStorageFull()
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
    private func saveLastSession(atStart: Bool = false) {
        guard resumeOnLaunch else { LastSession.clear(); return }
        if pendingRestore != nil { return } // déjà gardée, pas encore relancée
        let positionMs = atStart ? 0 : UInt64(max(0, position(at: Date())) * 1000)
        guard current != nil, let last = LastSession(queue: queue, index: queueIndex, positionMs: positionMs) else {
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
        let request = playRequests
        let ids = last.tracks.map(\.id)
        Task {
            do {
                try await core.restoreQueue(ids: ids, index: UInt32(index), positionMs: index == last.index ? position : 0)
            } catch {
                // Autre lecture demandée entre-temps : elle décide seule (avant, la reprise revenait en attente et
                // figeait la barre de progression et le bouton lecture du titre lancé).
                guard request == playRequests else { return }
                loading = false
                pendingRestore = last // un nouvel appui sur lecture la retente (avant : plus rien ne se passait)
                // Titre gardé de nouveau affiché (avant : celui demandé, avec la position de l'autre).
                if queue.indices.contains(queueIndex) {
                    current = queue[queueIndex]
                    shownIndex = queueIndex
                }
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
    var settingsOpen = false {
        // « Barre d'onglets complète » figée tant que les Réglages sont ouverts : changer de barre reconstruit les pages,
        // et la feuille des Réglages (ouverte depuis l'une d'elles) se refermait. Figée dès l'ouverture : la figer au
        // changement arrivait après la reconstruction. La nouvelle barre arrive à la fermeture.
        didSet {
            guard settingsOpen != oldValue else { return }
            tabBarFullHeld = settingsOpen ? (UserDefaults.standard.object(forKey: "tabBarFull") as? Bool ?? true) : nil
        }
    }
    /// Valeur de « Barre d'onglets complète » affichée pendant que les Réglages sont ouverts (voir `settingsOpen`).
    private(set) var tabBarFullHeld: Bool?
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
            reloadProfileData()
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
            reloadProfileData()
            showToast(tr("Ton profil n'est plus accessible : %@ est ouvert.", current?.name ?? tr("profil principal")), seconds: 4)
            choosingProfile = true
        }
    }

    /// Ouvre un profil : bibliothèque, titres aimés et recommandations deviennent les siens ; la lecture continue.
    func switchProfile(_ p: Profile) async {
        guard let core, !switchingProfile else { return }
        if p.current {
            Self.savedProfile = p.id
            reloadProfileData()
            choosingProfile = false
            return
        }
        switchingProfile = true
        defer { switchingProfile = false }
        do {
            // Données d'avant la séparation par profil (historique, épinglés, dernière écoute) : rangées d'abord chez le
            // profil ouvert jusqu'ici. Sinon elles partaient au profil choisi (celles du titulaire données à un enfant).
            if Self.savedProfile == nil, let id = currentProfile?.id {
                Self.savedProfile = id
                ProfileData.migrate()
            }
            try await core.switchProfile(id: p.id)
            // Déconnexion pendant le changement : rien n'est gardé pour le compte suivant.
            guard loggedIn == true else { return }
            Self.savedProfile = p.id
            choosingProfile = false
            profileGeneration += 1
            // Historique de recherche et éléments épinglés : ceux de ce profil (gardés à part pour chacun).
            history = HistoryEntry.load()
            pins = Pin.load()
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
            // Titres aimés téléchargés : ceux de ce profil (le cœur garde ceux de chaque profil à part). Relus hors du fil
            // principal : avec des milliers de titres, l'écran se figeait.
            await refreshDownloadsInBackground()
            prefetch()
            for tab in openTabs { Task { await loadLibrary(tab, force: false) } }
        } catch {
            showToast(describe(error), seconds: 4)
        }
    }

    /// « Qui écoute ? » fermé sans choisir : le profil ouvert est gardé (la question n'est plus posée).
    func keepCurrentProfile() {
        if Self.savedProfile == nil, let id = currentProfile?.id {
            Self.savedProfile = id
            reloadProfileData()
        }
    }

    /// Profil enregistré changé : historique de recherche et épinglés relus pour lui. Avant, ceux du profil d'avant
    /// (enfant retiré du compte) restaient affichés pour le titulaire, puis écrasaient les siens à la sauvegarde suivante.
    private func reloadProfileData() {
        history = HistoryEntry.load()
        pins = Pin.load()
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
        noLyrics = [:]
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
                // Profil ouvert maintenant connu : la liste des téléchargements montre ses Titres aimés à lui. Relue hors du
                // fil principal (avant : l'app se figeait juste après l'animation de lancement avec une grosse bibliothèque).
                await refreshDownloadsInBackground()
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
            // Comme à l'ouverture de session : listes des téléchargements relues pour ce compte. Avant, après une session
            // expirée puis la connexion d'un autre compte, les Titres aimés téléchargés de l'ancien restaient affichés.
            forgetOfflineDetails()
            await refreshDownloadsInBackground()
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
        NowPlaying.update(track: nil, status: status, cover: nil)
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

    /// Session refusée par Deezer en cours d'utilisation : même chose qu'au lancement (écran de connexion).
    private func sessionExpired() {
        guard loggedIn == true else { return }
        accountGeneration += 1
        forgetAccountCopies()
        sessionRetryTask?.cancel()
        sessionRetryTask = nil
        BackgroundDownloadManager.shared.deezerSessionEnded()
        // Retour à l'écran de connexion (avant, l'app restait sur des onglets vides et chaque chargement réaffichait l'alerte).
        sessionReady = false
        loggedIn = false
        message = tr("Session Deezer expirée : reconnecte-toi.")
    }

    /// Déconnexion en cours : `loggedIn` reste vrai jusqu'à la fin, donc aucun téléchargement ne doit partir pendant ce temps.
    @ObservationIgnored private var loggingOut = false

    func logout() async {
        guard let core else { return }
        loggingOut = true
        defer { loggingOut = false }
        accountGeneration += 1
        // Réponses encore en route (synchro des téléchargements…) : plus appliquées pendant la déconnexion.
        profileGeneration += 1
        BackgroundDownloadManager.shared.stopAll()
        BackgroundDownloadManager.shared.deezerSessionEnded()
        // Modifications des téléchargements en cours finies avant (leurs messages arrivaient après la déconnexion).
        await downloadEdits?.value
        // Téléchargements ajoutés à la file par ces modifications (avant : écrits dans la file et repris au compte suivant).
        BackgroundDownloadManager.shared.stopAll()
        do { try await core.logout() } catch { message = describe(error) }
        // Ouverture de session lancée pendant la déconnexion (réseau revenu, nouvel essai) : elle ne rouvre pas le compte.
        accountGeneration += 1
        // Profil choisi oublié : un autre compte peut se connecter.
        Self.savedProfile = nil
        profileGeneration += 1
        settingsOpen = false
        profiles = []
        choosingProfile = false
        // Plus rien du compte en mémoire ni sur le téléphone (le cœur a déjà effacé session, cookies, trousseau et copies).
        bytesTask?.cancel()
        bytesTask = nil
        bytesAgain = false
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
        noLyrics = [:]
        likeTasks = [:]
        likeGeneration = [:]
        creditsTrack = nil
        playlistTrack = nil
        deletingPlaylist = nil
        showFullPlayer = false
        clearHistory()
        pendingRestore = nil
        LastSession.clear()
        pins = []
        Pin.save(pins)
        ProfileData.clearAll() // historique, épinglés et dernière écoute de chaque profil
        skippedDownloads = []
        saveSkippedDownloads()
        homeOrder = []
        UserDefaults.standard.removeObject(forKey: "homeOrder")
        libraryOrder = [] // ordre des playlists du compte
        UserDefaults.standard.removeObject(forKey: "libraryOrder")
        setLovedTitle("")
        setMp3Title("") // nom de la page MP3 choisi sur ce téléphone : oublié aussi
        coverTarget = nil
        pickingCover = false
        lovedCard = nil
        customCovers = [:]
        CustomCovers.store(customCovers)
        CustomCovers.removeAll()
        CoverLoader.shared.clear()
        NowPlaying.update(track: nil, status: status, cover: nil)
        // Plus aucune reprise automatique en attente, ni de minuterie.
        resumePolicy = ResumePolicy()
        setSleepTimer(nil)
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
    /// `fresh` : rechargement forcé (playlist créée ou supprimée…) ; un chargement déjà en cours a pu partir avant le
    /// changement, il est attendu puis refait (avant, sa réponse était reprise : la nouvelle playlist manquait).
    private func once(_ key: String, fresh: Bool = false, _ work: @escaping () async -> Void) async {
        if let running = inFlight[key] {
            await running.value
            guard fresh else { return }
            if let other = inFlight[key], other != running { return await other.value } // déjà relancé par un autre
        }
        let task = Task { await work() }
        inFlight[key] = task
        await task.value
        if inFlight[key] == task { inFlight[key] = nil }
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
        // Hors ligne : rien n'est demandé (l'erreur s'afficherait à chaque visite) ; sans copie, « Réessayer » s'affiche.
        guard force || networkSignature != "none" else { if home == nil { setLoadFailed("home", true) }; return }
        let gen = profileGeneration
        setLoadFailed("home", false)
        await once("home#\(gen)", fresh: force) {
            // En cas d'erreur, la copie affichée reste. Profil changé entre-temps : réponse ignorée.
            let fresh = await self.load(nil as [Shelf]?, { try await $0.home() })
            guard gen == self.profileGeneration else { return }
            if let fresh {
                self.home = fresh
                self.refreshPins(fresh.flatMap(\.items))
                self.refreshed.insert("home")
            }
            // Échec : redemandé à la prochaine visite et au retour du réseau (avant, plus jamais : squelettes sans fin).
            self.setLoadFailed("home", fresh == nil)
        }
    }

    /// Accueil (« home ») ou rubrique de la bibliothèque (« library0 »…) en échec : sans copie à afficher, l'écran
    /// propose « Réessayer ».
    private(set) var loadFailed: Set<String> = []

    private func setLoadFailed(_ key: String, _ failed: Bool) {
        guard failed != loadFailed.contains(key) else { return } // inchangé : les écrans ne sont pas redessinés
        if failed { loadFailed.insert(key) } else { loadFailed.remove(key) }
    }

    /// 0 = playlists, 1 = albums, 2 = artistes.
    func loadLibrary(_ tab: Int, force: Bool) async {
        let key = "library\(tab)"
        guard sessionReady, force || !refreshed.contains(key) else { return }
        guard force || networkSignature != "none" else { if library[tab] == nil { setLoadFailed(key, true) }; return }
        let gen = profileGeneration
        setLoadFailed(key, false)
        await once("\(key)#\(gen)", fresh: force) {
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
                self.refreshed.insert(key)
            }
            self.setLoadFailed(key, fresh == nil)
        }
    }

    private func localDetail(_ route: Route) -> Detail? {
        guard let core else { return nil }
        // Pas de copie sur le téléphone il y a moins de 10 s : pas relue. Une page en cours de chargement est recréée
        // plusieurs fois, et chaque lecture passait par le disque, sur le fil principal.
        let now = Date()
        if let at = noLocalDetail[route], now.timeIntervalSince(at) < 10 { return nil }
        let found: Detail? = switch route {
        case .detail(let kind, let id, _): core.offlineDetail(kind: kind, id: id)
        case .loved: core.offlineDetail(kind: "loved", id: 0)
        case .mix: nil
        }
        if noLocalDetail.count > 40 { noLocalDetail = noLocalDetail.filter { now.timeIntervalSince($0.value) < 10 } }
        noLocalDetail[route] = found == nil ? now : nil
        return found
    }

    @ObservationIgnored private var noLocalDetail: [Route: Date] = [:]

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
        if detailOrder.count > maxDetails {
            let old = detailOrder.removeFirst()
            details[old] = nil
            detailDay[old] = nil
        }
    }

    func cachedDetail(_ route: Route) -> Detail? {
        // Hors ligne, une copie hors ligne déjà en mémoire suffit : relue sur le disque à chaque fois, elle ralentissait
        // l'ouverture des pages (des milliers de titres convertis sur le fil principal).
        if let hit = details[route], hit.offline || networkSignature != "none" { return hit }
        if networkSignature == "none", let saved = localDetail(route) {
            cacheDetail(saved, for: route)
            return saved
        }
        if let hit = details[route] { return hit }
        // Copie du téléphone gardée en mémoire : la page est recréée souvent pendant son chargement, et une playlist
        // téléchargée de milliers de titres était relue et convertie à chaque fois. La version de Deezer la remplace
        // dès son arrivée (`detail` ne ressert jamais une copie hors ligne quand Deezer répond).
        guard let saved = localDetail(route) else { return nil }
        cacheDetail(saved, for: route)
        return saved
    }

    func detail(_ route: Route, force: Bool) async -> Detail? {
        if (!sessionReady || networkSignature == "none"), let saved = localDetail(route) {
            cacheDetail(saved, for: route)
            return saved
        }
        // Copie hors ligne gardée pendant une coupure (ou avant l'ouverture de la session) : plus resservie une fois
        // Deezer joignable, sinon la page restait limitée aux titres du téléphone jusqu'à un rafraîchissement manuel.
        // Page MP3 : toujours redemandée (un MP3 importé ou renommé sur l'ordinateur doit y apparaître).
        if !force, let hit = details[route], !hit.offline, !hasNewReleases(hit, route: route), !route.isMp3 { return hit }
        let gen = profileGeneration
        let edits = lovedEdits
        let result: Detail? = await load(nil as Detail?) { core in
            switch route {
            case .detail(let kind, let id, _): return try await core.openDetail(kind: kind, id: id)
            case .mix(let key, _): return try await core.openMix(key: key)
            case .loved:
                return try await core.lovedDetail()
            }
        }
        // Profil changé pendant le chargement : la page s'affiche, mais n'est ni gardée ni reprise ailleurs.
        // Titres aimés demandés avant un « j'aime » : affichés, mais ni gardés ni repris pour les cœurs (le titre tout
        // juste aimé y manque encore).
        let staleLoved = route == .loved && !lovedListCurrent(since: edits)
        if let result, gen == profileGeneration, !staleLoved {
            cacheDetail(result, for: route)
            // Copie hors ligne : seulement les titres du téléphone, pas la liste complète des aimés.
            if case .loved = route, !result.offline { lovedIds = Set(result.tracks.map(\.id)) }
            // MP3 téléchargés : le cœur leur a donné le nom actuel, la liste des téléchargements suit.
            if route.isMp3, !result.offline {
                if result.tracks.contains(where: { downloadedIds.contains($0.id) }) {
                    forgetOfflineDetails()
                    await refreshDownloadsInBackground()
                }
            }
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
        let edits = lovedEdits
        guard let list = await load(nil as [Track]?, { try await $0.loved() }), gen == profileGeneration,
              lovedListCurrent(since: edits) else { return }
        lovedIds = Set(list.map(\.id))
    }

    /// Change à chaque « j'aime » : une liste des titres aimés demandée avant ne remplace plus les cœurs (avant, le cœur
    /// d'un titre aimé pendant le chargement s'éteignait, alors que Deezer l'avait bien enregistré).
    @ObservationIgnored private var lovedEdits = 0
    /// Liste des titres aimés demandée depuis `since` : à jour s'il n'y a eu aucun « j'aime » depuis, ni d'envoi en cours.
    private func lovedListCurrent(since: Int) -> Bool { since == lovedEdits && likeTasks.isEmpty }

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
        lovedEdits += 1
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
                // Profil changé entre-temps : ses cœurs à lui ne sont pas touchés. Un appui plus récent sur ce cœur décide
                // seul (avant, l'échec d'un ancien envoi éteignait le cœur d'un titre aimé juste après, chez Deezer).
                if gen == profileGeneration, likeGeneration[track.id] == mine {
                    if liked { lovedIds.remove(track.id) } else { lovedIds.insert(track.id) }
                    showToast(describe(error), seconds: 4)
                }
            }
            // Dernier envoi pour ce titre terminé : plus rien à attendre, il n'est plus gardé.
            if likeGeneration[track.id] == mine {
                likeTasks[track.id] = nil
                likeGeneration[track.id] = nil
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
        guard let core else { return }
        let before = beforePlay()
        pendingRestore = nil
        activateOutput()
        current = tracks[index]
        isFlow = false
        startLoading()
        let (ids, id) = (tracks.map(\.id), tracks[index].id)
        do {
            try core.play(ids: ids, index: UInt32(index))
        } catch CoreError.UnknownTrack {
            // Fiches oubliées par le cœur (grosse page ouverte avant d'autres) : redemandées à Deezer par paquets.
            // Avant : « Titre inconnu » et 20 s de chargement sur les titres du haut des grosses listes.
            Task {
                do { try await core.restoreQueue(ids: ids, index: UInt32(index), positionMs: 0) }
                catch { playFailed(error, before: before, ifShowing: id) }
            }
        } catch {
            playFailed(error, before: before, ifShowing: id)
        }
    }

    /// État d'avant une lecture demandée, remis par `playFailed` si rien n'a démarré.
    private func beforePlay() -> (current: Track?, isFlow: Bool, restore: LastSession?) {
        // Flow encore en chargement (titre provisoire) : c'est ce qui jouait avant lui qui revient si la lecture suivante
        // échoue. Avant, le titre provisoire revenait, et le mini-lecteur restait bloqué sur « Flow – Chargement… ».
        if current?.id == 0, let saved = beforeFlow { return saved }
        return (current, isFlow, pendingRestore)
    }

    @ObservationIgnored private var beforeFlow: (current: Track?, isFlow: Bool, restore: LastSession?)?

    /// Rien n'a démarré : le titre qui joue reste affiché (écran verrouillé aussi), le Flow reste marqué, et une
    /// dernière écoute en attente reste reprenable (avant : le bouton lecture ne faisait plus rien).
    private func playFailed(_ error: Error, before: (current: Track?, isFlow: Bool, restore: LastSession?), ifShowing id: Int64?) {
        // Autre lecture demandée depuis (autre titre affiché) : elle garde son indicateur de chargement, et pas de message
        // pour une demande abandonnée.
        guard current?.id == id else { return }
        loading = false
        current = before.current
        isFlow = before.isFlow
        pendingRestore = before.restore
        // État réel du moteur relu (l'état gardé pouvait dater de plusieurs minutes : la barre de l'écran
        // verrouillé reculait).
        refreshStatus()
        showToast(describe(error), seconds: 4)
    }

    func playFlow() {
        guard let core else { return }
        let before = beforePlay()
        beforeFlow = before
        pendingRestore = nil
        activateOutput()
        isFlow = true
        // Le Flow met un moment à arriver (recommandations, puis premier titre) : le mini-lecteur s'affiche aussitôt,
        // en chargement, au lieu de rien (on ne savait pas si l'appui avait été pris en compte).
        current = Track(id: 0, title: "Flow", artist: tr("Chargement…"), album: "", durationS: 0, coverUrl: nil,
                        quality: nil, artistId: 0, albumId: 0, addedAt: nil, releaseDate: nil, artists: [])
        startLoading()
        Task {
            do {
                try await core.playFlow()
            } catch {
                playFailed(error, before: before, ifShowing: 0)
            }
        }
    }

    /// Lance le mix inspiré d'un titre (« Mixes inspirés par » de l'accueil).
    func playTrackMix(_ id: UInt64) {
        guard let core else { return }
        let before = beforePlay()
        // Titre affiché au moment de la demande (le titre provisoire de Flow s'il charge encore). Avant, c'était le titre
        // d'avant Flow : un mix en échec pendant le chargement de Flow ne montrait aucun message, et le chargement restait 20 s.
        let showing = current?.id
        pendingRestore = nil
        activateOutput()
        isFlow = false
        startLoading()
        Task {
            do { try await core.playTrackMix(id: Int64(id)) } catch { playFailed(error, before: before, ifShowing: showing) }
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
        // Le cœur a quelque chose à jouer : moteur lancé tout de suite (voir `AudioOutput.resumeNow`). Hors de l'app, attendu
        // avant de mettre l'écran verrouillé à jour : iOS y montre l'état réel du son.
        if core?.status().playing == true {
            AudioOutput.resumeNow(wait: UIApplication.shared.applicationState != .active)
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
        showOnLockScreen(Status(playing: false, positionMs: 0, durationMs: 0), sharp: false)
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
        if sleepTimer == .trackEnd { scheduleSleep() }
    }

    // MARK: Minuterie de sommeil

    /// Arrêt de la musique après un délai, ou à la fin du titre en cours. Désactivée par défaut, jamais gardée d'un
    /// lancement à l'autre ; réglée dans la bulle « Son » du lecteur.
    enum SleepTimer: Hashable {
        case minutes(Int)
        case trackEnd
    }
    private(set) var sleepTimer: SleepTimer?
    /// Échéance d'une minuterie en minutes (décompte affiché dans la bulle « Son »).
    private(set) var sleepAt: Date?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// « Fin du titre » : titre et heure d'arrêt de la tâche en cours (voir `scheduleSleep`).
    @ObservationIgnored private var sleepPlan: (id: Int64, end: Date)?
    /// Volume pendant le fondu de fin (1 : normal).
    @ObservationIgnored private var sleepVolume: Float = 1
    /// Le son baisse doucement pendant ces secondes avant la pause (pas d'arrêt net).
    private static let sleepFade: Double = 8

    func setSleepTimer(_ timer: SleepTimer?) {
        cancelSleepTask()
        sleepTimer = timer
        sleepAt = nil
        restoreSleepVolume()
        switch timer {
        case .minutes(let m)?:
            sleepAt = Date().addingTimeInterval(Double(m) * 60)
            showToast(tr("La musique s'arrêtera dans %@ min", "\(m)"))
        case .trackEnd?:
            showToast(tr("La musique s'arrêtera à la fin du titre"))
        case nil:
            break
        }
        scheduleSleep()
    }

    /// Une seule tâche qui dort jusqu'à l'échéance (aucun réveil régulier), puis 8 s de fondu. Fin du titre : refaite à
    /// chaque changement (autre titre, saut, pause, reprise) ; rien ne tourne en pause.
    private func scheduleSleep() {
        let delay: Double
        switch sleepTimer {
        case .minutes?:
            guard let at = sleepAt else { return }
            delay = at.timeIntervalSinceNow
        case .trackEnd?:
            // En pause : le son est déjà coupé, le volume revient à la normale pour la reprise.
            guard status.playing, status.durationMs > 0, let id = current?.id else {
                cancelSleepTask()
                restoreSleepVolume()
                return
            }
            // Avec le fondu enchaîné, le titre suivant commence avant la fin : arrêt juste avant lui.
            delay = Double(status.durationMs) / 1000 - position(at: Date()) - Double(crossfade) - 0.3
            let end = Date().addingTimeInterval(delay)
            // Même titre, même échéance (à 1 s près) : la tâche en cours continue. Avant, chaque état envoyé pendant la
            // lecture la relançait : le fondu recommençait sans fin, la pause n'arrivait jamais, et les titres suivants
            // continuaient à jouer sans le son.
            if sleepTask != nil, let plan = sleepPlan, plan.id == id, abs(plan.end.timeIntervalSince(end)) < 1 { return }
            // Titre fini pendant le fondu (durée annoncée un peu plus longue que le son) : c'était la fin demandée, la
            // musique s'arrête maintenant. Avant, le titre suivant jouait en entier à plein volume.
            if let plan = sleepPlan, plan.id != id, sleepVolume < 1 {
                cancelSleepTask()
                finishSleep()
                return
            }
            sleepPlan = (id, end)
            // Nouvelle échéance (déplacement dans le titre pendant le fondu…) : le son revient d'abord à la normale,
            // sinon le nouveau fondu partait du volume déjà baissé et la suite jouait à 20 %.
            sleepTask?.cancel()
            restoreSleepVolume()
        case nil:
            cancelSleepTask()
            restoreSleepVolume()
            return
        }
        sleepTask?.cancel()
        sleepTask = Task { [weak self] in
            let fade = min(Self.sleepFade, max(delay, 0))
            try? await Task.sleep(for: .seconds(max(delay - fade, 0)))
            // Le son baisse par petits pas (5 par seconde), en courbe : la fin s'entend comme un vrai fondu.
            let steps = max(Int(fade * 5), 1)
            let from = self?.sleepVolume ?? 1
            for i in 0..<steps {
                guard !Task.isCancelled, let self else { return }
                let left = 1 - Double(i + 1) / Double(steps)
                self.sleepVolume = from * Float(left * left)
                self.core?.setVolume(volume: self.sleepVolume)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, let self else { return }
            self.finishSleep()
        }
    }

    private func cancelSleepTask() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepPlan = nil
    }

    private func finishSleep() {
        sleepTask = nil
        sleepPlan = nil
        sleepTimer = nil
        sleepAt = nil
        pause()
        // Volume normal une fois le son coupé (la pause le fait descendre à zéro) : la reprise se fait normalement.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.restoreSleepVolume()
        }
    }

    private func restoreSleepVolume() {
        guard sleepVolume < 1 else { return }
        sleepVolume = 1
        core?.setVolume(volume: 1)
    }

    func queueAdd(_ tracks: [Track], next: Bool) {
        let pending = editPendingQueue { queue, index in queue.insert(contentsOf: tracks, at: next ? index + 1 : queue.count) }
        if !pending, let core {
            let ids = tracks.map(\.id)
            // Fiche oubliée par le cœur : redemandée à Deezer avant l'ajout (d'où l'attente).
            Task {
                do { try await core.queueAdd(ids: ids, next: next) } catch { showToast(describe(error), seconds: 4) }
            }
        }
        showToast(next ? tr("Lu juste après") : tr("Ajouté à la file"))
    }

    /// Oublie les copies hors ligne gardées en mémoire (session rouverte, réseau revenu).
    private func forgetOfflineDetails() {
        noLocalDetail = [:] // téléchargements changés : une page sans copie peut en avoir une maintenant
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
        detailDay = [:]
        lyricsCache = [:]
    }

    /// Ouvre une page depuis le lecteur plein écran (qui se ferme), dans l'onglet affiché.
    func navigate(_ route: Route) {
        showFullPlayer = false
        requestedRoute = route
    }

    func showToast(_ text: String, seconds: Double = 2) {
        toast = text
        UIAccessibility.post(notification: .announcement, argument: text) // VoiceOver lit aussi le message
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

    // MARK: MP3 importés (Bibliothèque › MP3), comme sur le site de Deezer.

    /// Sélecteur de fichier ouvert (import d'un MP3).
    var importingMp3 = false
    /// Fenêtre nom / artiste / pochette ouverte.
    var mp3Editor: Mp3Edit? {
        // Fenêtre fermée (ou remplacée) : la copie du fichier faite pour l'app est supprimée. Seulement là : cachée un
        // instant par une autre fenêtre, elle restait ouverte mais son fichier disparaissait.
        didSet { if let old = oldValue?.file, old != mp3Editor?.file { try? FileManager.default.removeItem(at: old) } }
    }
    /// MP3 dont la suppression attend la confirmation.
    var deletingMp3: Track?
    /// Augmente après un import, une modification ou une suppression : la page MP3 se recharge.
    private(set) var mp3Revision = 0

    /// Pochette choisie sur ce téléphone pour un MP3 importé (Deezer ne permet pas de la changer une fois envoyé).
    func mp3Cover(_ track: Track?) -> String? {
        guard let track, track.id < 0 else { return nil }
        return customCovers["mp3\(track.id)"]
    }

    /// Écran verrouillé : titre affiché, avec la même pochette que dans l'app (avant, celle de Deezer même pour un MP3
    /// importé avec une pochette choisie). `sharp` : voir `NowPlaying.update`.
    private func showOnLockScreen(_ status: Status, sharp: Bool = true) {
        NowPlaying.update(track: current, status: status, cover: cover(current), sharp: sharp && skipTarget == nil)
    }

    /// Pochette d'un titre à afficher : celle choisie ici pour un MP3 importé, sinon celle enregistrée sur le téléphone,
    /// sinon celle de Deezer (remplacée si elle n'existe plus, comme dans les listes : avant, les pochettes voisines du
    /// carrousel restaient vides puis changeaient d'un coup).
    func cover(_ track: Track?) -> String? {
        guard let track else { return nil }
        if let mp3 = mp3Cover(track) { return mp3 }
        if let saved = track.coverUrl, !saved.hasPrefix("http") { return saved }
        return coverFixes[track.id] ?? track.coverUrl
    }

    /// Fichier choisi : nom et artiste lus dans le fichier pour préremplir la fenêtre.
    /// `url` : copie du fichier faite pour l'app ; la fenêtre la garde (lue à l'envoi) et la supprime en se fermant.
    func importMp3(from url: URL) async {
        // Seul le début est lu ici (nom, artiste, album), hors du fil principal.
        let head: Data? = await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 1 << 20)
        }.value
        guard let head, !head.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            showToast(tr("Fichier illisible."), seconds: 4)
            return
        }
        let tags = core?.mp3Tags(head: head)
        mp3Editor = Mp3Edit(track: nil, file: url, fileName: url.lastPathComponent,
                            title: tags?.title ?? url.deletingPathExtension().lastPathComponent, artist: tags?.artist ?? "",
                            album: tags?.album ?? "")
    }

    /// Import (envoi sur le compte) ou modification d'un MP3.
    /// `cut` (import) : partie gardée en ms, `end` 0 = jusqu'à la fin ; `nil` = le fichier entier.
    /// Renvoie `false` en cas d'échec (message affiché) : la fenêtre reste alors ouverte.
    @discardableResult
    func saveMp3(_ edit: Mp3Edit, title: String, artist: String, album: String, cover: Data?, resetCover: Bool = false,
                 cut: (start: UInt64, end: UInt64)? = nil) async -> Bool {
        guard let core else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let url = edit.file {
                showToast(tr("Envoi du MP3…"), seconds: 30)
                // Lu seulement maintenant, hors du fil principal.
                guard let file = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url, options: .alwaysMapped) }).value else {
                    showToast(tr("Fichier illisible."), seconds: 4)
                    return false
                }
                _ = try await core.personalUpload(fileName: edit.fileName, mp3: file, title: title, artist: artist, album: album, cover: cover,
                                                  startMs: cut?.start ?? 0, endMs: cut?.end ?? 0)
                showToast(tr("« %@ » importé", title))
                refreshMp3s(again: true)
            } else if let track = edit.track {
                // Champ vidé : l'artiste et l'album d'avant restent (Deezer refuse une modification sans eux).
                if title != track.title || (!artist.isEmpty && artist != track.artist) || (!album.isEmpty && album != track.album) {
                    try await core.personalUpdate(id: track.id, title: title, artist: artist.isEmpty ? track.artist : artist,
                                                  album: !album.isEmpty ? album : track.album.isEmpty ? "MP3" : track.album)
                    // Copie téléchargée renommée par le cœur : la liste des téléchargements suit.
                    if downloadedIds.contains(track.id) {
                        forgetOfflineDetails()
                        await refreshDownloadsInBackground()
                    }
                }
                if resetCover, cover == nil {
                    let key = "mp3\(track.id)"
                    customCovers[key] = nil
                    CustomCovers.store(customCovers)
                    CustomCovers.remove(key: key)
                }
                if let cover {
                    let key = "mp3\(track.id)"
                    if let url = await Task.detached(priority: .userInitiated, operation: { CustomCovers.save(cover, key: key) }).value {
                        customCovers[key] = url
                        CustomCovers.store(customCovers)
                    }
                }
                showToast(cover != nil ? tr("MP3 modifié · pochette changée sur ce téléphone seulement") : tr("MP3 modifié"), seconds: cover != nil ? 3 : 2)
                refreshMp3s()
            }
            return true
        } catch {
            showToast(describe(error), seconds: 4)
            return false
        }
    }

    func deleteMp3(_ track: Track) async {
        guard let core else { return }
        do {
            showToast(tr("Suppression du MP3…"), seconds: 30)
            let playlists = try await core.personalDelete(id: track.id)
            // Retiré aussi des titres aimés et des playlists : leurs pages gardées en mémoire seront rechargées.
            lovedIds.remove(track.id)
            details[.loved] = nil
            for id in playlists { forgetDetail(kind: "playlist", id: id) }
            // Plus sur le compte : la copie téléchargée part aussi.
            // Plus sur le compte : la copie téléchargée (ou en cours de téléchargement) part aussi.
            if downloadedIds.contains(track.id) || downloadStates[track.id] != nil { removeDownload(track.id) }
            let key = "mp3\(track.id)"
            if customCovers[key] != nil {
                customCovers[key] = nil
                CustomCovers.store(customCovers)
                CustomCovers.remove(key: key)
            }
            showToast(tr("MP3 supprimé"))
            refreshMp3s()
        } catch {
            showToast(describe(error), seconds: 4)
        }
    }

    /// Page MP3 rechargée ; après un envoi, encore une fois quelques secondes plus tard (le titre peut tarder à y apparaître).
    private func refreshMp3s(again: Bool = false) {
        mp3Revision += 1
        guard again else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            mp3Revision += 1
        }
    }

    /// Appui long sur un titre > « Ajouter à une playlist » : titre pour lequel la fenêtre des playlists est ouverte.
    var playlistTrack: Track?
    /// Playlist dont la suppression attend la confirmation.
    var deletingPlaylist: Card?

    /// Crée une playlist (avec ces titres, éventuellement aucun). `false` si Deezer refuse (message affiché).
    @discardableResult
    func createPlaylist(_ title: String, with tracks: [Track] = []) async -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let core, !name.isEmpty else { return false }
        do {
            _ = try await core.playlistCreate(title: name, trackIds: tracks.map(\.id))
            showToast(tracks.isEmpty ? tr("Playlist « %@ » créée", name) : tr("Ajouté à « %@ »", name))
            await loadLibrary(0, force: true)
            return true
        } catch {
            showToast(describe(error), seconds: 4)
            return false
        }
    }

    /// Supprime une de ses playlists chez Deezer (après confirmation). Elle quitte aussi l'accueil si elle y était épinglée.
    func deletePlaylist(_ card: Card) async {
        guard let core else { return }
        do {
            try await core.playlistDelete(playlistId: card.id)
            if let i = pins.firstIndex(where: { $0.matches(card) }) {
                let removed = HomeItem.pin(pins[i]).id
                pins.remove(at: i)
                if homeOrder.contains(removed) { setHomeOrder(homeOrder.filter { $0 != removed }) }
                Pin.save(pins)
            }
            library[0]?.removeAll { $0.kind == "playlist" && $0.id == card.id }
            forgetDetail(kind: "playlist", id: card.id)
            showToast(tr("Playlist supprimée"))
            await loadLibrary(0, force: true)
        } catch {
            showToast(describe(error), seconds: 4)
        }
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
        // Rafale de suivant / précédent encore ouverte : abandonnée (sinon sa fin renvoyait son titre par-dessus celui
        // touché), et le titre touché devient celui attendu (le « suivant » d'après part de lui, ses annonces s'affichent).
        skipWindow?.cancel()
        skipWindow = nil
        skipTarget = nil
        sentTarget = nil
        if queue.indices.contains(index) {
            current = queue[index]
            shownIndex = index
            awaiting = (index, Date())
        }
        startLoading()
        attempt { try $0.queuePlay(index: UInt32(index)) }
    }

    /// Indicateur jusqu'au signal « son lancé » du cœur ; retiré de toute façon après 20 s (réseau coupé...).
    @ObservationIgnored private var loadingTimeout: Task<Void, Never>?
    /// Change à chaque lecture demandée (titre, file, suivant…) : l'échec d'une demande dépassée ne touche plus à rien.
    @ObservationIgnored private var playRequests = 0
    private func startLoading() {
        playRequests &+= 1
        loading = true
        // Une rafale de suivant / précédent ne laisse pas une tâche en attente par appui.
        loadingTimeout?.cancel()
        loadingTimeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            loading = false
        }
    }
    func queueRemove(_ index: Int) {
        let pending = editPendingQueue { queue, current in
            guard queue.indices.contains(index), index != current else { return }
            queue.remove(at: index)
            if index < current { current -= 1 }
        }
        if !pending { attempt { try $0.queueRemove(index: UInt32(index)) } }
    }

    /// `to` : position finale du titre (déjà corrigée du décalage de SwiftUI).
    func queueMove(from: Int, to: Int) {
        let pending = editPendingQueue { queue, current in
            guard queue.indices.contains(from), queue.indices.contains(to) else { return }
            queue.insert(queue.remove(at: from), at: to)
            if from == current { current = to }
            else if from < current, to >= current { current -= 1 }
            else if from > current, to <= current { current += 1 }
        }
        if !pending { attempt { try $0.queueMove(from: UInt32(from), to: UInt32(to)) } }
    }

    /// Dernière écoute pas encore relancée : le cœur n'a pas encore de file, la modification est faite sur la file
    /// affichée et gardée pour la reprise. Avant, un ajout lançait le titre ajouté pendant que l'app restait affichée
    /// en pause, et le bouton lecture relançait ensuite l'ancienne file. `false` : pas de reprise en attente.
    private func editPendingQueue(_ change: (inout [Track], inout Int) -> Void) -> Bool {
        guard var last = pendingRestore else { return false }
        var tracks = queue, index = queueIndex
        change(&tracks, &index)
        guard tracks.indices.contains(index) else { return true }
        queue = tracks
        queueIndex = index
        shownIndex = index
        last.tracks = tracks.map { LastSession.SavedTrack($0) }
        last.index = index
        last.save()
        pendingRestore = last
        return true
    }

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
        showOnLockScreen(status)
    }

    private func refreshStatus() {
        syncStatus()
        showOnLockScreen(lockScreenStatus)
    }

    /// État montré sur l'écran verrouillé : à zéro pendant le chargement d'un titre (l'état du moteur est encore celui
    /// du précédent, affiché avec le nouveau nom).
    private var lockScreenStatus: Status { loading ? Status(playing: false, positionMs: 0, durationMs: 0) : status }

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
        case .Api(let m): return tr(m) // messages du cœur, en français : traduits s'ils sont connus
        // Détail du système (souvent en anglais) précédé d'un texte traduit : avant, le texte brut du cœur s'affichait seul.
        case .Keychain(let m): return tr("Trousseau de l'iPhone inaccessible : %@", m)
        case .Player: return tr("Lecteur indisponible.")
        case .UnknownTrack: return tr("Titre inconnu : recharge la page.")
        case .SessionExpired:
            // ARL expiré ou révoqué pendant que l'app restait ouverte : retour à l'écran de connexion. Avant, tout
            // échouait avec ce message jusqu'à ce que l'app soit tuée. Fait après coup : l'appelant finit d'abord.
            if loggedIn == true { Task { [weak self] in self?.sessionExpired() } }
            return tr("ARL invalide ou expiré.")
        case nil: return error.localizedDescription
        }
    }

    // MARK: Événements du cœur

    func handle(_ event: Event) {
        // Dernière écoute pas encore relancée : le premier état envoyé par le moteur (« en pause, 0:00 ») est ignoré,
        // sinon la reprise partirait du début.
        if pendingRestore != nil {
            switch event {
            case .state: return
            // Moteur encore vide : la file vide qu'il renvoie (aléatoire activé avant de relancer) effaçait la file
            // gardée, et lecture, suivant, précédent ne faisaient plus rien.
            case .queue(let tracks, _) where tracks.isEmpty: return
            default: break
            }
        }
        switch event {
        case .track(var track):
            // Rafale de suivant / précédent : un titre intermédiaire encore annoncé par le cœur (il traite les demandes une
            // par une) n'écrase plus celui demandé (avant, mini-lecteur, fond et écran verrouillé y repassaient un instant).
            if let target = skipTarget ?? awaitedIndex, queue.indices.contains(target), queue[target].id != track.id { break }
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
            // Message court du cœur (en français, traduit s'il est connu) : bulle discrète, pas une alerte à fermer.
            showToast(tr(m), seconds: 4)
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
            queueGeneration &+= 1
            queue = tracks
            queueIndex = Int(index)
            // Nouvelle file (autre album, playlist…) : un titre demandé dans l'ancienne n'est plus attendu (sinon le
            // « suivant » d'après partait de son index, dans la nouvelle file, pendant 20 s).
            awaiting = nil
        case .queueIndex(let index):
            let changed = queueIndex != Int(index)
            if changed { queueIndex = Int(index) }
            if awaiting?.index == Int(index) { awaiting = nil } // titre demandé confirmé
            // Dernière écoute gardée à chaque changement de titre : iOS peut fermer l'app suspendue sans prévenir
            // (et ne prévient pas non plus quand CarPlay l'a lancée en arrière-plan). Nouveau titre : gardé à son
            // début ; l'état du moteur peut encore être celui du précédent (fin du titre), qui arrive séparément.
            saveLastSession(atStart: changed)
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
            scheduleDownloadsRefresh() // hors du fil de l'interface (un contrôle de fichier par titre téléchargé)
        }
        switch event {
        case .track, .started, .state, .stopped, .closed:
            // Titre demandé en chargement : position et durée à zéro (les états reçus sont encore ceux de l'ancien titre,
            // affichés avec le nouveau nom sur l'écran verrouillé).
            showOnLockScreen(lockScreenStatus)
            // Minuterie « fin du titre » : échéance recalculée (autre titre, pause, reprise).
            if sleepTimer == .trackEnd { scheduleSleep() }
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
            // App suspendue par iOS pendant une pause : iOS l'annonce comme une coupure, sans fin à venir. Ignorée (rien ne
            // jouait), sinon elle restait « en cours » et bloquait les reprises automatiques. Valeur 1 = `.appWasSuspended`
            // (nom déclaré dépassé par Apple, valeur encore envoyée par certaines versions d'iOS).
            let suspended = (info[AVAudioSessionInterruptionReasonKey] as? UInt) == 1
            if type == .began && suspended {
                // iOS a coupé la session : marquée inactive, la prochaine lecture (écran verrouillé, CarPlay) la réactive
                // tout de suite au lieu d'attendre un nouvel essai.
                MainActor.assumeIsolated { AudioSession.invalidate() }
                return
            }
            // Traité tout de suite (file principale), comme les changements de sortie : avec un `Task`, une fin d'appel
            // pouvait passer après le changement de sortie qui l'accompagne, et la reprise était perdue.
            MainActor.assumeIsolated {
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
            let before = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs ?? []
            let previous = before.first { Self.earPorts.contains($0.portType) }?.uid
            // Sortie « mains libres » (casque, voiture) qui disparaît : c'est la fin d'un appel, pas des écouteurs retirés.
            let handsFree = before.contains { $0.portType == .bluetoothHFP }
            let current = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid)
            MainActor.assumeIsolated {
                guard let self else { return }
                if reason == .oldDeviceUnavailable {
                    // Fin d'appel en Bluetooth : la coupure en cours décide de la reprise. Avant, cette pause comptait comme
                    // un choix de l'utilisateur et la musique ne reprenait pas après l'appel.
                    if handsFree && self.resumePolicy.interrupted { return }
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
