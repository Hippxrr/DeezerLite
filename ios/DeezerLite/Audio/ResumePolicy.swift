import Foundation

/// Toutes les décisions de reprise automatique, au même endroit : après une coupure par une autre app,
/// au retour des écouteurs.
/// Règle commune : la musique ne repart toute seule que si elle jouait au moment où on l'a arrêtée à la place
/// de l'utilisateur, et que l'utilisateur n'a rien décidé depuis (lecture, pause, autre titre).
struct ResumePolicy {
    /// Une coupure est en cours (début reçu, fin pas encore).
    private(set) var interrupted = false
    /// La musique jouait (ou démarrait) quand la coupure en cours a commencé.
    private(set) var playingBeforeInterruption = false
    /// Pause due au retrait des écouteurs : leur identifiant et l'heure.
    private var earPause: (uid: String, at: Date)?

    /// Au-delà, des écouteurs remis ne relancent plus la musique.
    private static let earResumeWindow: TimeInterval = 30 * 60

    // MARK: Coupures

    /// Début d'une coupure. Une 2e coupure arrivée pendant la 1re (appel pendant un vocal) garde l'état d'avant
    /// la première : la musique y est déjà arrêtée, ce n'est pas l'utilisateur qui l'a voulu.
    mutating func interruptionBegan(playing: Bool) {
        if !interrupted { playingBeforeInterruption = playing }
        interrupted = true
    }

    /// Fin d'une coupure : faut-il relancer la musique ? Comme les autres apps de musique : seulement si l'app qui a
    /// pris le son le permet (`.shouldResume` d'iOS), et si la musique jouait (une pause d'avant l'appel est gardée).
    mutating func interruptionEnded(shouldResume: Bool) -> Bool {
        defer { interrupted = false; playingBeforeInterruption = false }
        return playingBeforeInterruption && shouldResume
    }

    // MARK: Écouteurs

    /// Écouteurs retirés (ou débranchés) pendant la lecture : on retient lesquels.
    mutating func earbudsRemoved(uid: String?, wasPlaying: Bool) {
        earPause = wasPlaying ? uid.map { ($0, Date()) } : nil
    }

    /// Changement de sortie : les mêmes écouteurs sont-ils revenus assez vite pour relancer la musique ?
    mutating func earbudsReturned(currentOutputs: [String]) -> Bool {
        guard let lost = earPause, currentOutputs.contains(lost.uid) else { return false }
        earPause = nil
        return Date().timeIntervalSince(lost.at) < Self.earResumeWindow
    }

    // MARK: Utilisateur

    /// Appui sur lecture, pause ou un autre titre : sa décision remplace toute reprise automatique en attente.
    /// La coupure, elle, reste en cours : sa fin ne relancera simplement rien.
    mutating func userDecided() {
        playingBeforeInterruption = false
        earPause = nil
        // iOS n'envoie pas toujours la fin d'une coupure (autre app qui garde le son) : sans ça, `interrupted` restait vrai
        // pour de bon (plus de reprise au retour des écouteurs, ni après l'appel suivant). Une fin tardive ne relance rien.
        interrupted = false
    }
}
