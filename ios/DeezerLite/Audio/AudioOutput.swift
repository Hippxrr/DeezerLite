import AVFoundation
import dz_ffiFFI

/// Sortie du son : AVAudioEngine tire le son du cœur Rust par `dz_render`, appelée sur le thread temps réel d'iOS
/// (sans UniFFI : ni allocation ni attente). Le cœur décide quand jouer : il appelle `start` / `stop` (lecture,
/// pause, nouveau titre). AVAudioEngine suit seul la sortie choisie par iOS (AirPods, haut-parleur, CarPlay) et
/// convertit vers sa fréquence ; après un appel, il est simplement relancé (plus de sortie à rouvrir).
enum AudioOutput {
    /// Format envoyé par le cœur (la même valeur que `ios_out::RATE` dans dz-audio).
    private static let rate: Double = 44_100
    /// Le moteur n'est manipulé que sur cette file : les ordres du cœur arrivent de son propre thread.
    private static let queue = DispatchQueue(label: "dz.audio-output", qos: .userInitiated)
    private static var engine: AVAudioEngine?
    /// Dernier ordre du cœur : après un changement de sortie, le moteur ne repart que s'il devait jouer.
    private static var wanted = false
    /// Numéro de la dernière demande de démarrage : une série d'essais plus ancienne s'arrête d'elle-même (elle ne
    /// doit ni continuer en parallèle, ni mettre en pause une lecture relancée entre-temps).
    private static var startID = 0

    /// À appeler une fois, avant de créer le cœur (sinon ses premiers ordres seraient perdus).
    static func install() {
        dz_output_set_hooks({ AudioOutput.request(true) }, { AudioOutput.request(false) })
        // Sortie changée (AirPods, enceinte, CarPlay) : iOS arrête le moteur ; il repart s'il jouait. Petit délai : des
        // écouteurs débranchés déclenchent aussi une pause, qui doit arriver avant (pas de redémarrage pour rien).
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
            queue.asyncAfter(deadline: .now() + 0.3) {
                // En pause : arrêté pour de bon (un moteur seulement suspendu repartirait sur l'ancienne sortie) ; la
                // reprise le reconstruit sur la nouvelle.
                guard wanted else { engine?.stop(); return }
                startID += 1
                start(id: startID)
            }
        }
        // Coupure (appel, vocal, autre app) : moteur arrêté pour de bon (voir `interrupted`).
        if #available(iOS 27.0, *) {
            // iOS 27 : une coupure arrive comme une désactivation de la session par le système. L'ancienne notification y
            // est dépassée ; une seule des deux est suivie (sinon chaque coupure serait traitée deux fois). Les
            // désactivations demandées par l'app elle-même ne sont pas des coupures.
            NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { note in
                guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                      context.source == .system else { return }
                interrupted(suspended: context.interruptionContext?.reason.rawValue == 1)
            }
        } else {
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                interrupted(suspended: (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) == 1)
            }
        }
        // Service audio d'iOS redémarré : l'ancien moteur n'est plus utilisable, un neuf est créé à la prochaine
        // lecture. Pas de redémarrage ici : la session audio n'est pas encore reconfigurée (le lecteur s'en charge,
        // puis se met en pause) ; démarrer maintenant jouait un instant avec les réglages par défaut d'iOS.
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            queue.async {
                engine = nil
                startID += 1 // une série d'essais en cours s'arrête
            }
        }
    }

    /// Début d'une coupure : moteur arrêté pour de bon. Seulement suspendu, il pouvait rester muet à la reprise (iOS a
    /// détaché le matériel) ; arrêté, il repart proprement. `suspended` : app suspendue pendant une pause (raison 1,
    /// `.appWasSuspended`), annoncée seulement au réveil, souvent juste après l'appui sur lecture qui l'a réveillée. Avant,
    /// le moteur que cet appui venait de relancer était arrêté : silence, puis le son ne revenait qu'au relancement suivant
    /// (environ 1 s). Arrêté seulement s'il est encore en pause.
    private static func interrupted(suspended: Bool) {
        queue.async { if !(suspended && wanted) { engine?.stop() } }
    }

    /// Pause plus longue que ça : le moteur est arrêté pour de bon (batterie), comme la sortie du bureau.
    private static let pauseKeep: Double = 60

    fileprivate static func request(_ run: Bool) {
        queue.async {
            wanted = run
            // En pause, le moteur ne tourne plus (pas de silence envoyé) : iOS sait que rien ne joue.
            startID += 1
            if run {
                start(id: startID)
            } else {
                // Suspendu 0,15 s plus tard : le cœur fait descendre le son en 5 ms, mais iOS joue encore le tampon déjà
                // rendu (jusqu'à 0,1 s écran verrouillé). Suspendu tout de suite, ce tampon était coupé net : un petit clic
                // à la pause, sur certains titres. Une reprise entre-temps annule la suspension.
                // `pause` (le moteur garde ce qu'il a préparé) : la reprise est immédiate. Avant, `stop` libérait tout et
                // `start` devait tout reconstruire : le son mettait un moment à revenir, et le Centre de contrôle montrait
                // « pause » pendant ce temps (iOS n'y affiche « lecture » que quand le son sort vraiment).
                // Arrêt complet après `pauseKeep`, et dès une coupure (voir `install`) : un moteur seulement suspendu
                // pouvait rester muet après un appel ou un vocal (iOS a détaché le matériel).
                let id = startID
                queue.asyncAfter(deadline: .now() + 0.15) {
                    guard id == startID, !wanted else { return }
                    engine?.pause()
                    queue.asyncAfter(deadline: .now() + pauseKeep) {
                        if id == startID, !wanted { engine?.stop() }
                    }
                }
            }
        }
    }

    /// Reprise par l'utilisateur : moteur lancé d'ici, sans attendre l'aller-retour par les fils du cœur (qui le demandera
    /// ensuite, sans effet). `wait` (écran verrouillé, Centre de contrôle) : attendu 0,5 s au plus, pour que le son tourne
    /// déjà quand la commande rend la main. Avant, iOS voyait encore le moteur arrêté et le Centre de contrôle repassait
    /// sur « lecture » avant « pause ».
    static func resumeNow(wait: Bool) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            wanted = true
            startID += 1
            start(id: startID)
            done.signal()
        }
        if wait { _ = done.wait(timeout: .now() + 0.5) }
    }

    /// Démarre le moteur. Juste après une coupure, iOS peut refuser un court instant (l'autre app rend encore le son) :
    /// nouvel essai jusqu'à 5 fois, toutes les 0,3 s, tant que le cœur veut toujours jouer.
    /// `id` : la demande à laquelle répond cette série d'essais (voir `startID`).
    private static func start(id: Int, attempt: Int = 1) {
        let e = engine ?? make()
        engine = e
        guard !e.isRunning else { return }
        dz_output_restarting() // le son repart en fondu (iOS a pu arrêter le moteur sans le laisser descendre)
        // Session réactivée juste avant le premier essai (ici, hors du fil principal) : après une pause, iOS suspend l'app et
        // coupe sa session. Avant, le premier démarrage échouait alors, et le son ne revenait qu'au nouvel essai, 0,3 s plus
        // tard (et le Centre de contrôle restait sur « pause » pendant ce temps). Sans effet si elle est déjà active.
        if attempt == 1 { try? AVAudioSession.sharedInstance().setActive(true) }
        do {
            try e.start()
        } catch {
            guard id == startID else { return }
            guard attempt < 5 else {
                giveUp(id)
                return
            }
            queue.asyncAfter(deadline: .now() + 0.3) {
                let session = AVAudioSession.sharedInstance()
                // Demande plus récente arrivée entre-temps : elle a sa propre série d'essais.
                guard id == startID, wanted else { return }
                // Une autre app joue (vocal, autre lecteur) : on ne lui reprend pas le son. Le lecteur passe en pause,
                // pour ne pas afficher « lecture » sans son (aucune fin de coupure ne viendrait le relancer).
                if session.secondaryAudioShouldBeSilencedHint {
                    giveUp(id)
                    return
                }
                // La session a pu être refusée elle aussi à la fin de la coupure : redemandée avant le nouvel essai.
                try? session.setActive(true)
                start(id: id, attempt: attempt + 1)
            }
        }
    }

    /// Le moteur ne démarre pas : le cœur passe en pause, l'affichage dit vrai, et un appui sur lecture relance le
    /// moteur. Seulement si c'est toujours la dernière demande et que rien n'a relancé le moteur entre-temps.
    private static func giveUp(_ id: Int) {
        let text = tr("Le son n'a pas pu reprendre : appuie sur lecture.")
        Task { @MainActor in
            let stillDown: Bool = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                queue.async { done.resume(returning: id == startID && wanted && engine?.isRunning != true) }
            }
            guard stillDown else { return }
            Player.shared.outputGaveUp()
            Player.shared.showToast(text, seconds: 4)
        }
    }

    private static func make() -> AVAudioEngine {
        let e = AVAudioEngine()
        // Float 32 bits, un tampon par canal : `dz_render` remplit la gauche et la droite.
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                // Format inattendu : du silence plutôt que le contenu laissé dans les tampons.
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                return noErr
            }
            dz_render(left, right, frames)
            return noErr
        }
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.prepare()
        return e
    }
}
