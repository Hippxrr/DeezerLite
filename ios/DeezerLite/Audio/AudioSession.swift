import AVFoundation

enum AudioSession {
    /// Catégorie lecture : le son continue écran verrouillé et ignore le bouton silencieux.
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            // Tampon plus long = moins de réveils du CPU. Écran verrouillé, iOS passe de lui-même à 4096 trames.
            try session.setPreferredIOBufferDuration(0.046)
        } catch {
            print("AVAudioSession : \(error)")
        }
    }

    /// Session déjà active : `activate()` ne refait pas l'appel système (il peut prendre plusieurs millisecondes
    /// sur le thread principal, au moment même d'une animation de changement de titre).
    private static var active = false

    /// Activée seulement au moment de jouer : ouvrir l'app ne coupe pas la musique d'une autre app.
    static func activate() {
        guard !active else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            active = true
        } catch {
            print("AVAudioSession.setActive : \(error)")
        }
    }

    /// Déconnexion : on rend la main aux autres apps audio.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        active = false
    }

    /// iOS a coupé la session (appel, redémarrage du service audio) : la prochaine lecture la réactive.
    static func invalidate() {
        active = false
    }
}
