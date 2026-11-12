import CoreMotion

/// Retrait d'un seul AirPod : iOS met en pause les apps de l'App Store, mais n'envoie rien à celle-ci (vérifié sur
/// l'iPhone : ni commande, ni changement de sortie). Les capteurs de mouvement des AirPods, eux, se « déconnectent » dès
/// qu'un écouteur sort de l'oreille, et se « reconnectent » quand il revient : seuls ces deux signaux sont utilisés.
/// Les mouvements eux-mêmes ne sont jamais lus ni gardés, et rien n'est envoyé nulle part.
/// Allumés seulement pendant la lecture sur des écouteurs, ou tant qu'une reprise au retour de l'AirPod est attendue.
/// AirPods sans capteurs (AirPods 1 et 2) : rien ne change, seul le retrait des deux écouteurs met en pause.
@MainActor
final class EarDetection: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var running = false
    /// Arrêt différé : entre deux titres, l'état « en lecture » retombe un instant ; inutile d'éteindre et rallumer.
    private var stopTask: Task<Void, Never>?

    var onRemoved: (() -> Void)?
    var onReturned: (() -> Void)?

    // TEMPORAIRE (test AirPods) : seuls l'écouteur qui fournit le mouvement et l'heure de chaque mesure sont regardés
    // (rien d'autre n'est lu ni gardé), pour savoir si le retrait de l'autre AirPod se voit quelque part.
    private var lastLocation: Int?
    private var lastSample: TimeInterval?
    private var samples = 0
    /// `CMHeadphoneActivityManager` (iOS 18 et plus seulement).
    private var activity: AnyObject?

    override init() {
        super.init()
        manager.delegate = self
    }

    /// La première mise en marche demande l'autorisation « Mouvements et forme » ; refusée, rien ne se passe.
    func update(active: Bool) {
        if active {
            stopTask?.cancel()
            stopTask = nil
            guard !running, manager.isDeviceMotionAvailable else { return }
            running = true
            // TEMPORAIRE (test AirPods) : avec lecteur, pour voir quel écouteur fournit le mouvement.
            lastLocation = nil
            lastSample = nil
            AirPodsDiag.shared.log("Capteurs démarrés")
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                let location = motion?.sensorLocation.rawValue
                let message = error?.localizedDescription
                MainActor.assumeIsolated { self?.sample(location, message) }
            }
            startActivity()
        } else if running, stopTask == nil {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.stopTask = nil
                self.running = false
                self.manager.stopDeviceMotionUpdates()
                if #available(iOS 18, *) { (self.activity as? CMHeadphoneActivityManager)?.stopStatusUpdates() }
                AirPodsDiag.shared.log("Capteurs arrêtés")
            }
        }
    }

    // MARK: TEMPORAIRE (test AirPods)

    /// Écouteur qui fournit le mouvement (s'il change), coupures du flux de plus de 0,3 s, et un relevé toutes les 100
    /// mesures (pour voir le débit).
    private func sample(_ location: Int?, _ error: String?) {
        if let error {
            AirPodsDiag.shared.log("Capteurs : erreur \(error)")
            return
        }
        let now = Date().timeIntervalSince1970
        if let last = lastSample, now - last > 0.3 {
            AirPodsDiag.shared.log("Capteurs : aucune mesure pendant \(Int((now - last) * 1000)) ms")
        }
        lastSample = now
        samples += 1
        if samples % 100 == 0 { AirPodsDiag.shared.log("Capteurs : \(samples) mesures reçues") }
        guard location != lastLocation else { return }
        lastLocation = location
        let names = [0: "par défaut", 1: "AirPod gauche", 2: "AirPod droit"]
        AirPodsDiag.shared.log("Capteurs : mouvement fourni par \(location.flatMap { names[$0] } ?? "?")")
    }

    /// Autre service des AirPods (iOS 18) : son état « connecté / déconnecté » change peut-être aussi.
    private func startActivity() {
        guard #available(iOS 18, *) else { return }
        let activity = (self.activity as? CMHeadphoneActivityManager) ?? CMHeadphoneActivityManager()
        self.activity = activity
        guard activity.isStatusAvailable else {
            AirPodsDiag.shared.log("Activité des AirPods : indisponible")
            return
        }
        activity.startStatusUpdates(to: .main) { status, error in
            let text = error.map { "erreur \($0.localizedDescription)" } ?? (status == .connected ? "connecté" : "déconnecté")
            MainActor.assumeIsolated { AirPodsDiag.shared.log("Activité des AirPods : \(text)") }
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            AirPodsDiag.shared.log("Capteurs : AirPods déconnectés") // TEMPORAIRE (test AirPods)
            self.onRemoved?()
        }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            AirPodsDiag.shared.log("Capteurs : AirPods connectés") // TEMPORAIRE (test AirPods)
            self.onReturned?()
        }
    }
}
