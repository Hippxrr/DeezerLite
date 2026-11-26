import Foundation
import os
import UIKit

@MainActor
final class BackgroundDownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadManager()
    private static let sessionIdentifier = "dev.local.deezerlite.downloads"
    private static let maximumActive = 3
    /// Intervalle minimal entre deux mises à jour de progression d'un même titre.
    private nonisolated static let progressInterval: TimeInterval = 0.5

    private struct Job: Codable {
        let id: Int64
        let title: String
        let artist: String
        let coverURL: String?
        var preparedURL: String?
        var incomingPath: String?
        /// Titre déjà téléchargé, retéléchargé dans la qualité choisie (Réglages › Qualité, mise à jour).
        var upgrade: Bool?
        /// Qualité demandée (« FLAC »…), notée à la préparation : celle des Réglages peut changer avant la fin.
        var target: String?

        var track: Track {
            Track(id: id, title: title, artist: artist, album: "", durationS: 0, coverUrl: coverURL,
                  quality: nil, artistId: 0, albumId: 0, addedAt: nil, releaseDate: nil, artists: [])
        }
    }

    /// Événement de la session reçu avant la fin de `restore` (relance en arrière-plan) : rejoué ensuite.
    private struct DeferredEvent {
        let id: Int64
        let task: URLSessionDownloadTask
        let file: URL?
        let error: Error?
    }

    private weak var player: Player?
    private var core: Core?
    private var jobs: [Int64: Job] = [:]
    private var order: [Int64] = []
    private var failed: Set<Int64> = []
    private var tasks: [Int64: URLSessionDownloadTask] = [:]
    private var preparations: [Int64: Task<Void, Never>] = [:]
    private var finishing: Set<Int64> = []
    /// Titres déjà repréparés une fois après une adresse expirée (HTTP 403 / 410).
    private var renewed: Set<Int64> = []
    private var deferred: [DeferredEvent] = []
    private var restoring = true
    /// Fin de la restauration au lancement (voir `orphanGrace`).
    private var restoredAt: Date?
    /// Après une relance, un titre déjà préparé dont la tâche est inconnue a peut-être fini pendant que l'app était
    /// fermée : iOS peut livrer son fichier un peu après la restauration. On l'attend ce délai avant de le retélécharger.
    private static let orphanGrace: TimeInterval = 10
    private var deezerSessionReady = false
    /// Réseau disponible (relevé du système, transmis par `Player`). Sans réseau, rien n'est préparé : avant, chaque
    /// essai échouait aussitôt et toute la file passait en « Échec » en quelques secondes.
    private var networkUp = true
    /// Réseau actuel en données mobiles (et pas en Wi-Fi).
    private var onCellular = false
    /// Réglages › Qualité › « Télécharger en Wi-Fi seulement » : en données mobiles, rien n'est préparé ni téléchargé.
    static let wifiOnlyKey = "downloadsWifiOnly"
    private var wifiOnly: Bool { UserDefaults.standard.bool(forKey: Self.wifiOnlyKey) }
    /// En données mobiles avec « Wi-Fi seulement » : les titres attendent le Wi-Fi.
    private var waitingForWifi: Bool { wifiOnly && onCellular }
    /// Titres arrêtés par une coupure : gardés en file (pas en échec), ils repartent quand le réseau revient.
    private var waitingNetwork: Set<Int64> = []
    /// Titres coupés en cours de route (réseau, app fermée de force) dont iOS a donné de quoi reprendre : ils repartent
    /// de là où ils s'étaient arrêtés (voir `resumeDirectory`). Avant, ils reprenaient tout depuis le début.
    private var resumable: Set<Int64> = []
    /// Téléchargements en cours repris de cette façon (leur échec non réseau fait repartir de zéro, une fois).
    private var fromResume: Set<Int64> = []
    /// Plus de place sur l'iPhone : la file est arrêtée (chaque titre suivant échouait pareil, après avoir été
    /// téléchargé pour rien), les titres restent en attente. Reprise au retour dans l'app, à une nouvelle demande, ou
    /// au lancement suivant.
    private var storageFull = false
    /// Nouvel essai des titres arrêtés quand le réseau semble là mais que Deezer ne répond pas (portail Wi-Fi…).
    private var networkRetry: Task<Void, Never>?
    private static let networkRetryDelay: Duration = .seconds(30)
    /// Essais d'affilée sans réussite : l'attente double à chaque fois (30 s, 1 min, 2 min… jusqu'à 15 min). Avant, un
    /// Wi-Fi sans Internet (hôtel, partage de connexion sans données) relançait tout toutes les 30 s, sans fin.
    private var networkRetryCount = 0
    private var backgroundCompletion: (() -> Void)?
    private var backgroundEventsFinished = false
    /// Dernière progression envoyée par titre, filtrée sur le thread de la session : le thread principal ne reçoit plus
    /// une tâche par paquet reçu.
    private nonisolated let progressStamps = OSAllocatedUnfairLock(initialState: [Int64: Date]())

    private lazy var session: URLSession = {
        // Une session background attend toujours le réseau : `waitsForConnectivity` n'y sert à rien.
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = Self.maximumActive
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private nonisolated static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("deezer-lite/Downloads", isDirectory: true)
    }

    /// Données de reprise, une par titre : à part d'`Incoming` (dont les fichiers non référencés sont effacés au lancement).
    private nonisolated static var resumeDirectory: URL {
        storageDirectory.appendingPathComponent("Resume", isDirectory: true)
    }

    private func resumeURL(_ id: Int64) -> URL { Self.resumeDirectory.appendingPathComponent("\(id).resume") }

    /// Gardé pour reprendre plus tard ; l'adresse préparée et le titre attendu par le cœur restent.
    private func keepForResume(_ id: Int64, _ data: Data) {
        try? FileManager.default.createDirectory(at: Self.resumeDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: resumeURL(id), options: .completeFileProtectionUntilFirstUserAuthentication)) != nil else { return }
        resumable.insert(id)
        save()
        player?.downloadUpdated(DownloadUpdate(id: id, state: .queued, progress: 0, error: nil))
    }

    private func dropResume(_ id: Int64) {
        guard resumable.remove(id) != nil else { return }
        try? FileManager.default.removeItem(at: resumeURL(id))
    }

    /// Taille complète attendue du fichier : celle annoncée (réponse 200), ou le total de « Content-Range » d'une reprise
    /// (réponse 206, seule la fin du fichier est envoyée).
    private nonisolated static func expectedSize(_ response: URLResponse?) -> Int64? {
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 206 {
            return http.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last }.flatMap { Int64($0) }
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    private nonisolated static func incomingURL(id: Int64, taskIdentifier: Int) -> URL {
        storageDirectory.appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent("\(id)-\(taskIdentifier).download")
    }

    private var jobsURL: URL { Self.storageDirectory.appendingPathComponent("native-jobs.json") }
    /// Titres en cours seulement (adresse préparée, fichier reçu) : petit fichier écrit tout de suite à chaque étape. La
    /// file complète (des milliers de titres possibles) est regroupée : avant, elle était réécrite en entier deux fois par
    /// titre (jusqu'à ~1 Go écrit pour 3 000 titres).
    private var activeURL: URL { Self.storageDirectory.appendingPathComponent("native-active.json") }

    private struct ActiveStep: Codable {
        let id: Int64
        let preparedURL: String?
        let incomingPath: String?
    }

    /// Ordre de la file (affichage des téléchargements dans l'ordre où ils ont été demandés).
    var queueOrder: [Int64] { order }

    private override init() {
        super.init()
    }

    /// À appeler au lancement de l'app, avant `handleBackgroundSession` (iOS peut relancer l'app en arrière-plan
    /// juste pour livrer les téléchargements terminés : le cœur doit déjà être là).
    func configure(core: Core, player: Player) {
        guard self.core == nil else { return }
        self.core = core
        self.player = player
        load()
        let queued = order.compactMap { jobs[$0] }
        player.restoreDownloadQueue(queued.map(\.track), upgrades: Set(queued.filter { $0.upgrade == true }.map(\.id)))
        _ = session
        session.getAllTasks { [weak self] sessionTasks in
            Task { @MainActor in self?.restore(sessionTasks) }
        }
        // Passage en arrière-plan : la file en attente d'écriture est écrite avant une éventuelle suspension.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    func deezerSessionIsReady() {
        deezerSessionReady = true
        // Session ouverte : Deezer répond, les titres arrêtés par une coupure repartent.
        resumeWaitingForNetwork()
    }

    /// Session refusée par Deezer ou compte fermé : plus aucun titre n'est préparé (chaque essai échouerait) jusqu'à la
    /// prochaine connexion.
    func deezerSessionEnded() {
        deezerSessionReady = false
    }

    /// Changement de réseau (appelé à chaque relevé du système).
    /// `newNetwork` : un autre réseau qu'avant (Wi-Fi <-> données mobiles, retour du réseau). Seulement alors les titres
    /// en attente repartent tout de suite ; sur le même réseau (iOS en redonne des nouvelles souvent), c'est la minuterie
    /// qui décide. Avant, chaque nouvelle relançait toute la file : sur un Wi-Fi sans Internet, l'attente grandissante
    /// entre deux essais ne servait à rien.
    func networkChanged(up: Bool, newNetwork: Bool, cellular: Bool) {
        let wasUp = networkUp
        let wasCellular = onCellular
        networkUp = up
        onCellular = cellular
        // Passage Wi-Fi <-> données mobiles : la règle « Wi-Fi seulement » est appliquée aux téléchargements en cours.
        if wasCellular != cellular { applyCellularRule() }
        guard up, !wasUp || (newNetwork && !waitingNetwork.isEmpty) else { return }
        networkRetryCount = 0 // nouveau réseau : on repart d'une attente courte
        resumeWaitingForNetwork()
    }

    /// Réglage « Wi-Fi seulement » changé dans les Réglages.
    func wifiOnlyChanged() {
        applyCellularRule()
    }

    /// En données mobiles, un téléchargement en cours qui ne suit plus le réglage repart de zéro avec le bon : autorisé en
    /// données mobiles alors que « Wi-Fi seulement » est activé (arrêté, il attendra le Wi-Fi), ou l'inverse (il restait
    /// bloqué jusqu'au Wi-Fi). En Wi-Fi, rien ne change : ils continuent. Puis la file repart (Wi-Fi retrouvé…).
    private func applyCellularRule() {
        if onCellular {
            let stale = tasks.filter { $0.value.originalRequest?.allowsCellularAccess == wifiOnly }.map(\.key)
            stale.forEach(requeue)
        }
        pump()
    }

    private func resumeWaitingForNetwork() {
        networkRetry?.cancel()
        networkRetry = nil
        waitingNetwork.removeAll()
        pump()
    }

    func resumeAfterStorageFull() {
        guard storageFull else { return }
        storageFull = false
        pump()
    }

    /// Plus de place sur l'iPhone (écriture du fichier reçu, ou copie dans les téléchargements par le cœur).
    private func isOutOfSpace(_ error: Error) -> Bool {
        if let coreError = error as? CoreError, case .Api(let message) = coreError { return message.contains("os error 28") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCannotWriteToFile || ns.code == NSURLErrorCannotCreateFile { return true }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// Titre arrêté faute de place : remis en file, et toute la file s'arrête (un seul message).
    private func waitForSpace(_ id: Int64) {
        if !storageFull { player?.showToast(tr("Plus assez de place sur l'iPhone : téléchargements en pause."), seconds: 6) }
        storageFull = true
        requeue(id)
        finishBackgroundEventsIfPossible()
    }

    /// Remis « En attente », sans passer en échec : adresse et fichier reçu oubliés, il repartira de zéro.
    private func requeue(_ id: Int64) {
        tasks.removeValue(forKey: id)?.cancel()
        dropResume(id)
        fromResume.remove(id)
        core?.cancelDownload(id: id)
        if var job = jobs[id] {
            if let path = job.incomingPath { try? FileManager.default.removeItem(atPath: path) }
            job.preparedURL = nil
            job.incomingPath = nil
            jobs[id] = job
        }
        save()
        player?.downloadUpdated(DownloadUpdate(id: id, state: .queued, progress: 0, error: nil))
    }

    /// Erreur due au réseau (absent, coupé, trop lent) plutôt qu'au titre lui-même.
    private func isNetworkError(_ error: Error) -> Bool {
        if !networkUp { return true }
        // Message du cœur pour toutes les erreurs de connexion (voir `friendly_error`).
        if let coreError = error as? CoreError, case .Api(let message) = coreError, message.hasPrefix("Connexion trop faible") || message.hasPrefix("Deezer ne répond pas") { return true }
        let ns = error as NSError
        let codes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                     NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        return ns.domain == NSURLErrorDomain && codes.contains(ns.code)
    }

    /// Titre arrêté par le réseau : remis en file (« En attente »), sans passer en échec. Avec des données de reprise, il
    /// repartira de là où il s'était arrêté (adresse préparée gardée) ; sinon, de zéro.
    private func waitForNetwork(_ id: Int64, resumeData: Data? = nil) {
        waitingNetwork.insert(id)
        if let resumeData {
            keepForResume(id, resumeData)
        } else {
            requeue(id)
        }
        // Réseau présent mais Deezer injoignable : nouvel essai plus tard (pas en boucle).
        if networkRetry == nil {
            let delay = min(Self.networkRetryDelay * (1 << min(networkRetryCount, 5)), .seconds(900))
            networkRetryCount += 1
            networkRetry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.networkRetry = nil
                if self.networkUp { self.resumeWaitingForNetwork() }
            }
        }
        pump()
        finishBackgroundEventsIfPossible()
    }

    func handleBackgroundSession(completionHandler: @escaping () -> Void) {
        // Cœur pas démarré (disque plein, fichiers protégés…) : rien ne peut être livré. iOS est prévenu tout de suite ;
        // avant, il attendait une fin qui ne venait jamais et finissait par limiter les relances de l'app.
        guard core != nil else { completionHandler(); return }
        backgroundCompletion = completionHandler
        _ = session
        // La session est créée au lancement de l'app : iOS peut avoir déjà livré tous ses événements avant cet appel. Avant,
        // le drapeau était remis à faux ici, et iOS n'était jamais prévenu de la fin (il peut alors limiter les relances).
        finishBackgroundEventsIfPossible()
    }

    func enqueue(_ tracks: [Track]) -> [Track] {
        storageFull = false // nouvelle demande : on réessaie (de la place a pu être libérée)
        var accepted: [Track] = []
        for track in tracks {
            if jobs[track.id] != nil {
                if retryFailed(track.id) { accepted.append(track) }
            } else {
                jobs[track.id] = Job(id: track.id, title: track.title, artist: track.artist,
                                     coverURL: track.coverUrl, preparedURL: nil, incomingPath: nil)
                order.append(track.id)
                accepted.append(track)
            }
        }
        save()
        pump()
        if waitingForWifi, !accepted.isEmpty {
            player?.showToast(tr("Téléchargement au retour du Wi-Fi (réglage « Wi-Fi seulement »)."), seconds: 4)
        }
        return accepted
    }

    /// Titre en échec redemandé : remis à zéro (fichier reçu et reprise oubliés) pour repartir.
    private func retryFailed(_ id: Int64) -> Bool {
        guard var job = jobs[id], failed.remove(id) != nil else { return false }
        renewed.remove(id)
        if let path = job.incomingPath { try? FileManager.default.removeItem(atPath: path) }
        dropResume(id)
        job.preparedURL = nil
        job.incomingPath = nil
        jobs[id] = job
        return true
    }

    /// Titres déjà téléchargés à retélécharger dans la qualité choisie (Réglages › Qualité). Ils restent écoutables :
    /// le nouveau fichier ne remplace l'ancien qu'une fois reçu en entier (voir `import_download` dans le cœur).
    func enqueueUpgrade(_ tracks: [Track]) -> [Track] {
        storageFull = false
        var accepted: [Track] = []
        for track in tracks {
            if jobs[track.id] != nil {
                // Mise à jour en échec : relancée. Avant, « Déjà en cours » tant que l'échec n'était pas effacé.
                if retryFailed(track.id) { accepted.append(track) }
            } else {
                jobs[track.id] = Job(id: track.id, title: track.title, artist: track.artist,
                                     coverURL: track.coverUrl, preparedURL: nil, incomingPath: nil, upgrade: true)
                order.append(track.id)
                accepted.append(track)
            }
        }
        save()
        pump()
        if waitingForWifi, !accepted.isEmpty {
            player?.showToast(tr("Téléchargement au retour du Wi-Fi (réglage « Wi-Fi seulement »)."), seconds: 4)
        }
        return accepted
    }

    func cancel(_ id: Int64) {
        cancel([id])
    }

    func cancel(_ ids: [Int64]) {
        let cancelled = Set(ids)
        core?.cancelDownloadList(ids: ids)
        for id in cancelled {
            preparations.removeValue(forKey: id)?.cancel()
            tasks.removeValue(forKey: id)?.cancel()
            dropResume(id)
            fromResume.remove(id)
            if let path = jobs[id]?.incomingPath { try? FileManager.default.removeItem(atPath: path) }
            jobs[id] = nil
            failed.remove(id)
            renewed.remove(id)
            waitingNetwork.remove(id)
        }
        progressStamps.withLock { stamps in cancelled.forEach { stamps[$0] = nil } }
        order.removeAll { cancelled.contains($0) }
        save()
        player?.downloadsStopped(ids)
        pump()
    }

    /// Retire de la file tous les téléchargements en échec.
    func clearFailed() {
        guard !failed.isEmpty else { return }
        cancel(Array(failed))
    }

    func stopAll() {
        preparations.values.forEach { $0.cancel() }
        preparations.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        core?.cancelDownloads()
        let cancelled = order
        jobs.removeAll()
        order.removeAll()
        failed.removeAll()
        renewed.removeAll()
        waitingNetwork.removeAll()
        resumable.removeAll()
        fromResume.removeAll()
        try? FileManager.default.removeItem(at: Self.resumeDirectory)
        networkRetry?.cancel()
        networkRetry = nil
        deferred.removeAll()
        progressStamps.withLock { $0.removeAll() }
        save()
        try? FileManager.default.removeItem(at: Self.storageDirectory.appendingPathComponent("Incoming", isDirectory: true))
        player?.downloadsStopped(cancelled)
    }

    private func restore(_ sessionTasks: [URLSessionTask]) {
        for case let task as URLSessionDownloadTask in sessionTasks {
            guard let raw = task.taskDescription, let id = Int64(raw), jobs[id] != nil else {
                task.cancel()
                continue
            }
            tasks[id] = task
        }
        restoring = false
        restoredAt = Date()
        // Événements arrivés pendant la restauration : rejoués maintenant que les tâches sont connues.
        let pending = deferred
        deferred.removeAll()
        for event in pending {
            received(id: event.id, task: event.task, file: event.file, error: event.error)
        }
        // Tâches d'avant la relance : remises à la règle « Wi-Fi seulement » si besoin (puis la file repart).
        applyCellularRule()
        finishBackgroundEventsIfPossible()
        // Titres préparés restés sans nouvelles pendant le délai de grâce : relancés ensuite.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.orphanGrace))
            self?.pump()
        }
    }

    /// Préparé avant la fermeture de l'app, tâche inconnue depuis la relance, délai de grâce pas encore écoulé.
    private func awaitingLateDelivery(_ job: Job) -> Bool {
        guard job.preparedURL != nil, job.incomingPath == nil, tasks[job.id] == nil,
              let restoredAt else { return false }
        return Date().timeIntervalSince(restoredAt) < Self.orphanGrace
    }

    private func pump() {
        guard !restoring, !storageFull, core != nil else { return }
        for id in order {
            // Déjà téléchargé : retiré de la file, sauf s'il y est pour une mise à jour de la qualité.
            if !finishing.contains(id), jobs[id]?.upgrade != true, player?.downloadedIds.contains(id) == true {
                removeRecoveredJob(id)
                continue
            }
            guard preparations.count + tasks.count + finishing.count < Self.maximumActive else { break }
            guard !failed.contains(id), !waitingNetwork.contains(id), !finishing.contains(id), preparations[id] == nil,
                  tasks[id] == nil, let job = jobs[id], !awaitingLateDelivery(job) else { continue }
            if job.incomingPath != nil {
                finish(job)
            } else if resumable.contains(id), job.preparedURL != nil {
                // Coupé en cours de route : repris là où il en était (adresse déjà préparée, pas besoin de Deezer).
                if networkUp, !waitingForWifi { resumeDownload(job) }
            } else if deezerSessionReady, networkUp, !waitingForWifi {
                prepare(job)
            }
        }
    }

    /// Reprend un téléchargement coupé là où il s'était arrêté. Données de reprise illisibles : il repartira de zéro.
    private func resumeDownload(_ job: Job) {
        let id = job.id
        let data = try? Data(contentsOf: resumeURL(id))
        dropResume(id)
        guard let data else {
            pump()
            return
        }
        let task = session.downloadTask(withResumeData: data)
        // Commencé avant un changement de « Wi-Fi seulement » : la reprise garde la règle de la requête d'origine. En
        // données mobiles, il restait alors bloqué jusqu'au Wi-Fi malgré le réglage désactivé : il repart de zéro.
        if onCellular, task.originalRequest?.allowsCellularAccess == wifiOnly {
            task.cancel()
            requeue(id)
            pump()
            return
        }
        task.taskDescription = String(id)
        tasks[id] = task
        fromResume.insert(id)
        task.resume()
    }

    private func prepare(_ job: Job) {
        guard let core else { return }
        let id = job.id
        dropResume(id) // nouvelle adresse : l'ancienne reprise ne vaut plus
        player?.downloadUpdated(DownloadUpdate(id: id, state: .queued, progress: 0, error: nil))
        preparations[id] = Task { [weak self] in
            do {
                let prepared = try await core.prepareDownload(id: id, replace: job.upgrade == true)
                guard let self, !Task.isCancelled, self.jobs[id] != nil else {
                    if self?.jobs[id] == nil { core.cancelDownload(id: id) }
                    self?.finishBackgroundEventsIfPossible()
                    return
                }
                self.preparations[id] = nil
                self.start(prepared, job: job)
                // Relance en arrière-plan : iOS attend ce signal pour suspendre l'app. Une préparation en cours le
                // retardait, et personne ne le redonnait une fois finie : il n'était jamais envoyé.
                self.finishBackgroundEventsIfPossible()
            } catch {
                guard let self, !Task.isCancelled, self.jobs[id] != nil else {
                    if self?.jobs[id] == nil { core.cancelDownload(id: id) }
                    self?.finishBackgroundEventsIfPossible()
                    return
                }
                self.preparations[id] = nil
                if case .NotBetter(let missing)? = error as? CoreError {
                    self.keepCurrentQuality(id, missing: missing)
                } else if self.isNetworkError(error) {
                    self.waitForNetwork(id)
                } else {
                    self.fail(id, error: error)
                }
            }
        }
    }

    /// Mise à jour de la qualité inutile, Deezer n'ayant pas mieux que le fichier gardé (voir `prepare_download`) : le
    /// titre sort de la file sans rien retélécharger. `missing` : qualité demandée que Deezer n'a pas (vide : déjà dedans).
    private func keepCurrentQuality(_ id: Int64, missing: String) {
        jobs[id] = nil
        renewed.remove(id)
        order.removeAll { $0 == id }
        save()
        if !missing.isEmpty { player?.markQualityUnavailable(id, wanted: missing) }
        player?.downloadsStopped([id])
        pump()
        finishBackgroundEventsIfPossible()
    }

    private func start(_ prepared: PreparedDownload, job: Job) {
        guard jobs[job.id] != nil, let url = URL(string: prepared.url) else {
            if jobs[job.id] != nil { fail(job.id, message: tr("Adresse du téléchargement invalide")) }
            return
        }
        var job = job
        job.preparedURL = prepared.url
        job.target = prepared.quality
        jobs[job.id] = job
        // Écrit tout de suite (sans attendre le regroupement) : l'adresse préparée sert à reconnaître, après une
        // relance, un fichier livré pendant que l'app était fermée.
        writeActive()
        save()
        // « Wi-Fi seulement » : si le Wi-Fi est perdu en cours de route, iOS met ce téléchargement en attente au lieu de
        // passer en données mobiles.
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !wifiOnly
        let task = session.downloadTask(with: request)
        task.taskDescription = String(job.id)
        tasks[job.id] = task
        task.resume()
    }

    private func received(id: Int64, task: URLSessionDownloadTask, file: URL?, error: Error?) {
        if restoring {
            deferred.append(DeferredEvent(id: id, task: task, file: file, error: error))
            return
        }
        // Tâche terminée pendant que l'app était fermée : absente de `getAllTasks`, mais son job l'attendait encore.
        if tasks[id] == nil, let job = jobs[id], job.preparedURL != nil, job.incomingPath == nil,
           !finishing.contains(id), preparations[id] == nil, !failed.contains(id) {
            tasks[id] = task
        }
        guard let current = tasks[id], current === task else {
            if let file { try? FileManager.default.removeItem(at: file) }
            finishBackgroundEventsIfPossible()
            return
        }
        tasks[id] = nil
        progressStamps.withLock { $0[id] = nil }
        guard var job = jobs[id] else {
            if let file { try? FileManager.default.removeItem(at: file) }
            finishBackgroundEventsIfPossible()
            return
        }
        let wasResumed = fromResume.remove(id) != nil
        if let error {
            // Ce qu'iOS a déjà reçu, pour reprendre plus tard là où il en était (coupure, app fermée de force).
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            // Téléchargement annulé par iOS, pas par l'app (app fermée de force depuis le sélecteur d'apps : iOS annule
            // alors toutes ses tâches et le signale au lancement suivant). Les annulations de l'app retirent la tâche
            // avant de l'annuler et n'arrivent jamais ici. Le titre repart simplement de la file, sans passer en échec :
            // de là où il en était si iOS le permet, sinon de zéro.
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
                if let resumeData, job.preparedURL != nil {
                    keepForResume(id, resumeData)
                    pump()
                    finishBackgroundEventsIfPossible()
                    return
                }
                core?.cancelDownload(id: id)
                job.preparedURL = nil
                jobs[id] = job
                save()
                player?.downloadUpdated(DownloadUpdate(id: id, state: .queued, progress: 0, error: nil))
                pump()
                finishBackgroundEventsIfPossible()
                return
            }
            // Adresse Deezer expirée (job resté longtemps en file) : une nouvelle adresse est demandée une fois.
            let code = (error as NSError).code
            if (error as NSError).domain == Self.errorDomain, code == 403 || code == 410, !renewed.contains(id) {
                renewed.insert(id)
                core?.cancelDownload(id: id)
                job.preparedURL = nil
                jobs[id] = job
                save()
                pump()
                finishBackgroundEventsIfPossible()
                return
            }
            if isNetworkError(error) {
                waitForNetwork(id, resumeData: job.preparedURL == nil ? nil : resumeData)
                return
            }
            // Reprise refusée (données de reprise périmées, fichier changé chez Deezer…) : une fois de zéro.
            if wasResumed {
                core?.cancelDownload(id: id)
                job.preparedURL = nil
                jobs[id] = job
                save()
                pump()
                finishBackgroundEventsIfPossible()
                return
            }
            fail(id, error: error)
            return
        }
        guard let file else {
            fail(id, message: tr("Fichier téléchargé introuvable"))
            return
        }
        job.incomingPath = file.path
        jobs[id] = job
        // Écrit tout de suite, pas après le regroupement : l'app fermée entre-temps perdait le fichier reçu (retéléchargé).
        writeActive()
        save()
        pump()
    }

    private func finish(_ job: Job) {
        networkRetryCount = 0 // un téléchargement a abouti : le réseau marche
        guard let core, let path = job.incomingPath else { return }
        let id = job.id
        finishing.insert(id)
        player?.downloadUpdated(DownloadUpdate(id: id, state: .downloading, progress: 1, error: nil))
        // Rangement du titre : iOS laisse le temps de le finir si l'app passe en arrière-plan juste à ce moment (sinon il
        // attendait le prochain réveil de l'app).
        // Temps d'arrière-plan écoulé avant la fin : la tâche est rendue tout de suite. Avant, il n'y avait pas de fin
        // d'urgence, et iOS tue alors l'app (relancée pour livrer une grosse série de téléchargements, par exemple).
        final class Ticket { var id = UIBackgroundTaskIdentifier.invalid }
        let ticket = Ticket()
        ticket.id = UIApplication.shared.beginBackgroundTask(withName: "download-finish") {
            UIApplication.shared.endBackgroundTask(ticket.id)
            ticket.id = .invalid
        }
        Task { [weak self] in
            defer {
                if ticket.id != .invalid {
                    UIApplication.shared.endBackgroundTask(ticket.id)
                    ticket.id = .invalid
                }
            }
            do {
                let track = try await core.finishDownload(id: id, path: path)
                guard let self else { return }
                self.finishing.remove(id)
                guard self.jobs[id]?.incomingPath == path else {
                    // Annulé pendant le rangement. Mise à jour de la qualité : le titre reste téléchargé (avant, il était
                    // supprimé en entier).
                    if job.upgrade != true { try? core.removeDownload(id: id) }
                    self.pump()
                    self.finishBackgroundEventsIfPossible()
                    return
                }
                try? FileManager.default.removeItem(atPath: path)
                self.jobs[id] = nil
                self.renewed.remove(id)
                self.order.removeAll { $0 == id }
                self.save()
                self.player?.downloadCompleted(track)
                // Mise à jour finie dans une autre qualité que celle demandée : Deezer ne l'a pas pour ce titre.
                if job.upgrade == true, let target = job.target, track.quality != target {
                    self.player?.markQualityUnavailable(id, wanted: target)
                }
                self.pump()
                self.finishBackgroundEventsIfPossible()
            } catch {
                guard let self else { return }
                self.finishing.remove(id)
                if self.jobs[id]?.incomingPath != path {
                    if job.upgrade != true { try? core.removeDownload(id: id) }
                    self.pump()
                    self.finishBackgroundEventsIfPossible()
                } else {
                    self.fail(id, error: error)
                }
            }
        }
    }

    private func fail(_ id: Int64, error: Error) {
        if isOutOfSpace(error) {
            waitForSpace(id)
            return
        }
        // Message du cœur tel quel (« Connexion trop faible… ») plutôt que la description générique de Swift.
        fail(id, message: player?.describe(error) ?? error.localizedDescription)
    }

    private func fail(_ id: Int64, message: String) {
        tasks.removeValue(forKey: id)?.cancel()
        dropResume(id)
        fromResume.remove(id)
        core?.cancelDownload(id: id)
        if var job = jobs[id] {
            if let path = job.incomingPath { try? FileManager.default.removeItem(atPath: path) }
            job.preparedURL = nil
            job.incomingPath = nil
            jobs[id] = job
        }
        failed.insert(id)
        save()
        player?.downloadUpdated(DownloadUpdate(id: id, state: .failed, progress: 0, error: message))
        pump()
        finishBackgroundEventsIfPossible()
    }

    private func load() {
        if FileManager.default.fileExists(atPath: jobsURL.path) {
            do {
                let data = try Data(contentsOf: jobsURL)
                let saved = try JSONDecoder().decode([Job].self, from: data)
                for job in saved where jobs[job.id] == nil {
                    jobs[job.id] = job
                    order.append(job.id)
                }
            } catch {
                // Fichier illisible : mis de côté plutôt qu'écrasé par la prochaine sauvegarde (une file vide), comme le
                // fait le cœur pour ses propres fichiers.
                let aside = jobsURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: jobsURL, to: aside)
                player?.downloadQueuePersistenceFailed()
            }
        }
        // Étapes en cours écrites à part (voir `activeURL`), plus récentes que la file complète.
        if let data = try? Data(contentsOf: activeURL), let steps = try? JSONDecoder().decode([ActiveStep].self, from: data) {
            for step in steps where jobs[step.id] != nil {
                if let url = step.preparedURL { jobs[step.id]?.preparedURL = url }
                if let path = step.incomingPath { jobs[step.id]?.incomingPath = path }
            }
        }
        let incoming = Self.storageDirectory.appendingPathComponent("Incoming", isDirectory: true)
        // Chemin enregistré par une version précédente : le dossier de l'app a pu changer de place (mise à jour). Le
        // fichier est retrouvé par son nom dans le dossier actuel ; avant, il était effacé et le titre retéléchargé.
        for (id, job) in jobs {
            guard let path = job.incomingPath else { continue }
            let current = incoming.appendingPathComponent((path as NSString).lastPathComponent).path
            if current != path { jobs[id]?.incomingPath = current }
        }
        // Reprises gardées : seulement celles d'un titre encore en file avec son adresse préparée.
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.resumeDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                if let id = Int64(file.deletingPathExtension().lastPathComponent), jobs[id]?.preparedURL != nil {
                    resumable.insert(id)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let referenced = Set(jobs.values.compactMap(\.incomingPath))
        if let files = try? FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
            for file in files where !referenced.contains(file.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func removeRecoveredJob(_ id: Int64) {
        if let path = jobs[id]?.incomingPath { try? FileManager.default.removeItem(atPath: path) }
        dropResume(id)
        core?.cancelDownload(id: id)
        jobs[id] = nil
        order.removeAll { $0 == id }
        failed.remove(id)
        renewed.remove(id)
        progressStamps.withLock { $0[id] = nil }
        save()
        player?.downloadCancelled(id)
        finishBackgroundEventsIfPossible()
    }

    /// Écritures de `native-jobs.json`, l'une après l'autre (la dernière demandée est toujours la plus récente).
    private let saveQueue = DispatchQueue(label: "dz.download-jobs", qos: .utility)
    private var pendingSave: Task<Void, Never>?

    /// Enregistre la file, regroupé et hors du thread principal. Avant, chaque étape de chaque titre (préparé, reçu,
    /// terminé, en échec) réécrivait tout le fichier sur le thread principal : avec 3 000 titres en file (~450 Ko),
    /// des milliers d'écritures pendant que l'interface défilait.
    private func save() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            // Les étapes qui ne doivent pas attendre sont écrites à part, tout de suite (voir `activeURL`).
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.writeJobs(wait: false)
        }
    }

    /// Écrit maintenant ce qui attend encore (l'app peut être suspendue juste après).
    private func flushSave() {
        if pendingSave != nil {
            writeJobs(wait: true)
        } else {
            saveQueue.sync {} // une écriture déjà lancée se termine
        }
    }

    private func writeJobs(wait: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        // Copie prise maintenant, sur le thread principal ; encodée et écrite ailleurs.
        let list = order.compactMap { jobs[$0] }
        let steps = activeSteps()
        let (url, stepsURL) = (jobsURL, activeURL)
        let directory = Self.storageDirectory
        let work: () -> Void = { [weak self] in
            do {
                let data = try JSONEncoder().encode(list)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                // Étapes en cours réécrites avec : les deux fichiers restent d'accord (plus d'étape d'un titre fini).
                try JSONEncoder().encode(steps).write(to: stepsURL, options: .atomic)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.player?.downloadQueuePersistenceFailed() } }
            }
        }
        if wait { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
    }

    private func activeSteps() -> [ActiveStep] {
        jobs.values.compactMap { job in
            job.preparedURL == nil && job.incomingPath == nil
                ? nil : ActiveStep(id: job.id, preparedURL: job.preparedURL, incomingPath: job.incomingPath)
        }
    }

    /// Étapes en cours seulement, tout de suite (voir `activeURL`).
    private func writeActive() {
        let steps = activeSteps()
        let (url, directory) = (activeURL, Self.storageDirectory)
        saveQueue.async {
            // Échec (disque plein) : la file complète, écrite peu après, les contient aussi.
            guard let data = try? JSONEncoder().encode(steps) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func finishBackgroundEventsIfPossible() {
        guard !restoring, backgroundEventsFinished, finishing.isEmpty, preparations.isEmpty,
              let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        backgroundEventsFinished = false
        // iOS suspend l'app juste après ce signal : la file est écrite avant.
        flushSave()
        completion()
    }

    private nonisolated static let errorDomain = "BackgroundDownloadManager"

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let raw = downloadTask.taskDescription, let id = Int64(raw) else { return }
        let now = Date()
        let due = progressStamps.withLock { stamps -> Bool in
            if let last = stamps[id], now.timeIntervalSince(last) < Self.progressInterval { return false }
            stamps[id] = now
            return true
        }
        guard due else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0
        Task { @MainActor in
            guard let current = self.tasks[id], current === downloadTask else { return }
            self.player?.downloadUpdated(DownloadUpdate(id: id, state: .downloading, progress: progress, error: nil))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let raw = downloadTask.taskDescription, let id = Int64(raw) else { return }
        let destination = Self.incomingURL(id: id, taskIdentifier: downloadTask.taskIdentifier)
        do {
            // Messages traduits ici : ils s'affichent tels quels dans la liste des téléchargements (avant : en français
            // quelle que soit la langue choisie).
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw NSError(domain: Self.errorDomain, code: response.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: tr("Le serveur a répondu HTTP %@", String(response.statusCode))])
            }
            // Comparé à la taille du fichier reçu : avec une reprise, les compteurs d'iOS ne portent que sur la fin du fichier.
            let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            if let expected = Self.expectedSize(downloadTask.response), let size, size != expected {
                throw NSError(domain: Self.errorDomain, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: tr("Le fichier téléchargé est incomplet")])
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            // Déplacé, pas copié : le fichier temporaire d'iOS est sur le même volume, aucune réécriture du FLAC.
            try FileManager.default.moveItem(at: location, to: destination)
            // Sur le thread principal, dans l'ordre d'arrivée (des tâches séparées pouvaient s'exécuter dans le désordre :
            // la fin des événements traitée avant le dernier fichier, et le signal à iOS envoyé trop tôt ou jamais).
            DispatchQueue.main.async { MainActor.assumeIsolated { self.received(id: id, task: downloadTask, file: destination, error: nil) } }
        } catch {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.received(id: id, task: downloadTask, file: nil, error: error) } }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let downloadTask = task as? URLSessionDownloadTask,
              let raw = task.taskDescription, let id = Int64(raw) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(id: id, task: downloadTask, file: nil, error: error) } }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.backgroundEventsFinished = true
                self.finishBackgroundEventsIfPossible()
            }
        }
    }
}
