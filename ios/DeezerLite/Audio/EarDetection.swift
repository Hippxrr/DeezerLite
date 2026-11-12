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
            manager.startDeviceMotionUpdates() // sans lecteur : les mouvements ne sont pas lus
        } else if running, stopTask == nil {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.stopTask = nil
                self.running = false
                self.manager.stopDeviceMotionUpdates()
            }
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.onRemoved?() }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.onReturned?() }
    }
}
