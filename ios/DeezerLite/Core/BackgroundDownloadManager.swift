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
    /// Titres arrêtés par une coupure : gardés en file (pas en échec), ils repartent quand le réseau revient.
    private var waitingNetwork: Set<Int64> = []
    /// Plus de place sur l'iPhone : la file est arrêtée (chaque titre suivant échouait pareil, après avoir été
    /// téléchargé pour rien), les titres restent en attente. Reprise au retour dans l'app, à une nouvelle demande, ou
    /// au lancement suivant.
    private var storageFull = false
    /// Nouvel essai des titres arrêtés quand le réseau semble là mais que Deezer ne répond pas (portail Wi-Fi…).
    private var networkRetry: Task<Void, Never>?
    private static let networkRetryDelay: Duration = .seconds(30)
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

    private nonisolated static func incomingURL(id: Int64, taskIdentifier: Int) -> URL {
        storageDirectory.appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent("\(id)-\(taskIdentifier).download")
    }

    private var jobsURL: URL { Self.storageDirectory.appendingPathComponent("native-jobs.json") }

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
        player.restoreDownloadQueue(order.compactMap { jobs[$0]?.track })
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

    /// Changement de réseau (appelé à chaque relevé du système).
    func networkChanged(up: Bool) {
        let wasUp = networkUp
        networkUp = up
        if up, !wasUp || !waitingNetwork.isEmpty {
            resumeWaitingForNetwork()
        }
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

    /// Titre arrêté par le réseau : remis en file (« En attente »), sans passer en échec.
    private func waitForNetwork(_ id: Int64) {
        waitingNetwork.insert(id)
        requeue(id)
        // Réseau présent mais Deezer injoignable : nouvel essai plus tard (pas en boucle).
        if networkRetry == nil {
            networkRetry = Task { [weak self] in
                try? await Task.sleep(for: Self.networkRetryDelay)
                guard !Task.isCancelled, let self else { return }
                self.networkRetry = nil
                if self.networkUp { self.resumeWaitingForNetwork() }
            }
        }
        pump()
        finishBackgroundEventsIfPossible()
    }

    func handleBackgroundSession(completionHandler: @escaping () -> Void) {
        backgroundCompletion = completionHandler
        backgroundEventsFinished = false
        _ = session
    }

    func enqueue(_ tracks: [Track]) -> [Track] {
        storageFull = false // nouvelle demande : on réessaie (de la place a pu être libérée)
        var accepted: [Track] = []
        for track in tracks {
            if var existing = jobs[track.id] {
                guard failed.contains(track.id) else { continue }
                failed.remove(track.id)
                renewed.remove(track.id)
                if let path = existing.incomingPath { try? FileManager.default.removeItem(atPath: path) }
                existing.preparedURL = nil
                existing.incomingPath = nil
                jobs[track.id] = existing
                accepted.append(track)
            } else {
                jobs[track.id] = Job(id: track.id, title: track.title, artist: track.artist,
                                     coverURL: track.coverUrl, preparedURL: nil, incomingPath: nil)
                order.append(track.id)
                accepted.append(track)
            }
        }
        save()
        pump()
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
        pump()
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
            if !finishing.contains(id), player?.downloadedIds.contains(id) == true {
                removeRecoveredJob(id)
                continue
            }
            guard preparations.count + tasks.count + finishing.count < Self.maximumActive else { break }
            guard !failed.contains(id), !waitingNetwork.contains(id), !finishing.contains(id), preparations[id] == nil,
                  tasks[id] == nil, let job = jobs[id], !awaitingLateDelivery(job) else { continue }
            if job.incomingPath != nil {
                finish(job)
            } else if deezerSessionReady, networkUp {
                prepare(job)
            }
        }
    }

    private func prepare(_ job: Job) {
        guard let core else { return }
        let id = job.id
        player?.downloadUpdated(DownloadUpdate(id: id, state: .queued, progress: 0, error: nil))
        preparations[id] = Task { [weak self] in
            do {
                let prepared = try await core.prepareDownload(id: id)
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
                if self.isNetworkError(error) {
                    self.waitForNetwork(id)
                } else {
                    self.fail(id, error: error)
                }
            }
        }
    }

    private func start(_ prepared: PreparedDownload, job: Job) {
        guard jobs[job.id] != nil, let url = URL(string: prepared.url) else {
            if jobs[job.id] != nil { fail(job.id, message: "Adresse du téléchargement invalide") }
            return
        }
        var job = job
        job.preparedURL = prepared.url
        jobs[job.id] = job
        // Écrit tout de suite (sans attendre le regroupement) : l'adresse préparée sert à reconnaître, après une
        // relance, un fichier livré pendant que l'app était fermée.
        writeJobs(wait: false)
        let task = session.downloadTask(with: url)
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
        if let error {
            // Téléchargement annulé par iOS, pas par l'app (app fermée de force depuis le sélecteur d'apps : iOS annule
            // alors toutes ses tâches et le signale au lancement suivant). Les annulations de l'app retirent la tâche
            // avant de l'annuler et n'arrivent jamais ici. Le titre repart simplement de la file, sans passer en échec.
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
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
                waitForNetwork(id)
                return
            }
            fail(id, error: error)
            return
        }
        guard let file else {
            fail(id, message: "Fichier téléchargé introuvable")
            return
        }
        job.incomingPath = file.path
        jobs[id] = job
        // Écrit tout de suite, pas 0,3 s plus tard : l'app fermée entre-temps perdait le fichier reçu (retéléchargé).
        writeJobs(wait: false)
        pump()
    }

    private func finish(_ job: Job) {
        guard let core, let path = job.incomingPath else { return }
        let id = job.id
        finishing.insert(id)
        player?.downloadUpdated(DownloadUpdate(id: id, state: .downloading, progress: 1, error: nil))
        Task { [weak self] in
            do {
                let track = try await core.finishDownload(id: id, path: path)
                guard let self else { return }
                self.finishing.remove(id)
                guard self.jobs[id]?.incomingPath == path else {
                    try? core.removeDownload(id: id)
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
                self.pump()
                self.finishBackgroundEventsIfPossible()
            } catch {
                guard let self else { return }
                self.finishing.remove(id)
                if self.jobs[id]?.incomingPath != path {
                    try? core.removeDownload(id: id)
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
                player?.downloadQueuePersistenceFailed()
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
        let referenced = Set(jobs.values.compactMap(\.incomingPath))
        if let files = try? FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
            for file in files where !referenced.contains(file.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func removeRecoveredJob(_ id: Int64) {
        if let path = jobs[id]?.incomingPath { try? FileManager.default.removeItem(atPath: path) }
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
            try? await Task.sleep(for: .milliseconds(300))
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
        let url = jobsURL
        let directory = Self.storageDirectory
        let work: () -> Void = { [weak self] in
            do {
                let data = try JSONEncoder().encode(list)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.player?.downloadQueuePersistenceFailed() } }
            }
        }
        if wait { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
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
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw NSError(domain: Self.errorDomain, code: response.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Le serveur a répondu HTTP \(response.statusCode)"])
            }
            let expected = downloadTask.countOfBytesExpectedToReceive
            if expected > 0, downloadTask.countOfBytesReceived != expected {
                throw NSError(domain: Self.errorDomain, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Le fichier téléchargé est incomplet"])
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
