import MediaPlayer
import SwiftUI
import UIKit

/// Écran verrouillé et Centre de contrôle. Mis à jour seulement aux changements de titre et d'état :
/// iOS fait avancer la position seul grâce à `elapsedPlaybackTime` et `playbackRate`.
@MainActor
enum NowPlaying {
    private static var shownTrack: Int64?
    private static var artwork: MPMediaItemArtwork?
    /// Position et vitesse envoyées en dernier, et quand.
    private static var sent: (elapsed: Double, rate: Double, at: Date) = (0, 0, .distantPast)

    /// iOS appelle ces commandes sur le thread principal.
    static func setup(_ player: Player) {
        let cc = MPRemoteCommandCenter.shared()
        // TEMPORAIRE (test AirPods) : `name` sert au journal des commandes reçues.
        func on(_ command: MPRemoteCommand, _ name: String, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { event in
                MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    AirPodsDiag.shared.log("Commande reçue : \(name)")
                    return action(event)
                }
            }
        }
        on(cc.playCommand, "lecture") { _ in player.resume(); return .success }
        on(cc.pauseCommand, "pause") { _ in player.pause(); return .success }
        on(cc.togglePlayPauseCommand, "lecture/pause") { _ in player.toggle(); return .success }
        // TEMPORAIRE (test AirPods) : pour voir si iOS envoie « stop » au retrait d'un AirPod.
        on(cc.stopCommand, "stop") { _ in player.pause(); return .success }
        on(cc.nextTrackCommand, "suivant") { _ in player.next(); return .success }
        on(cc.previousTrackCommand, "précédent") { _ in player.previous(); return .success }
        on(cc.changePlaybackPositionCommand, "position") { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(seconds: e.positionTime)
            return .success
        }
    }

    /// Suivant / précédent grisés sur l'écran verrouillé quand il n'y a pas de titre de ce côté.
    static func setSkips(next: Bool, previous: Bool) {
        let cc = MPRemoteCommandCenter.shared()
        if cc.nextTrackCommand.isEnabled != next { cc.nextTrackCommand.isEnabled = next }
        if cc.previousTrackCommand.isEnabled != previous { cc.previousTrackCommand.isEnabled = previous }
    }

    static func update(track: Track?, status: Status) {
        let center = MPNowPlayingInfoCenter.default()
        AirPodsDiag.shared.silentPlayer(playing: track != nil && status.playing) // TEMPORAIRE (test AirPods)
        guard let track else {
            center.nowPlayingInfo = nil
            if AirPodsDiag.on(AirPodsDiag.stateKey) { center.playbackState = .stopped } // TEMPORAIRE (test AirPods)
            shownTrack = nil
            artwork = nil
            return
        }
        if shownTrack != track.id {
            shownTrack = track.id
            artwork = nil
            if let url = track.coverUrl {
                let loader = CoverLoader.shared
                // Tout de suite : la grande si elle est prête (titre suivant préparé à l'avance), sinon la meilleure en mémoire.
                if let ready = loader.cached(url: url, pixels: 1000) ?? loader.anyCached(url: url) { artwork = makeArtwork(ready) }
                if loader.cached(url: url, pixels: 1000) == nil {
                    // Puis la version nette (1000 px), une seule à la fois, remplacée au titre suivant.
                    Task {
                        guard let image = await loader.image(url: url, pixels: 1000), shownTrack == track.id else { return }
                        artwork = makeArtwork(image)
                        guard var info = center.nowPlayingInfo else { return }
                        info[MPMediaItemPropertyArtwork] = artwork
                        let elapsed = sent.elapsed + sent.rate * Date().timeIntervalSince(sent.at)
                        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
                        sent = (elapsed, sent.rate, Date())
                        center.nowPlayingInfo = info
                    }
                }
            } else if let fallback = fallbackImage {
                artwork = makeArtwork(fallback) // titre sans pochette : l'image de secours, comme dans l'app
            }
        }
        let duration = status.durationMs > 0 ? Double(status.durationMs) / 1000 : Double(track.durationS)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(status.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: status.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Déclarée comme musique (pas vidéo) : ce qu'iOS regarde pour les commandes des AirPods.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        // TEMPORAIRE (test AirPods) : état annoncé à iOS (lecture ou pause), à chaque changement.
        if (status.playing ? 1.0 : 0.0) != sent.rate { AirPodsDiag.shared.log("Annoncé à iOS : \(status.playing ? "lecture" : "pause")") }
        center.nowPlayingInfo = info
        // TEMPORAIRE (test AirPods) : état de lecture déclaré à iOS. Apple le dit utile surtout sur Mac (sur iPhone, iOS le
        // devine d'après le son de l'app), mais c'est peut-être ce qu'il regarde avant d'envoyer la pause au retrait d'un AirPod.
        if AirPodsDiag.on(AirPodsDiag.stateKey) { center.playbackState = status.playing ? .playing : .paused }
        sent = (Double(status.positionMs) / 1000, status.playing ? 1 : 0, Date())
    }

    /// Image de secours dessinée une seule fois (titre sans pochette).
    private static let fallbackImage: UIImage? = {
        // Fond sombre quel que soit le mode de l'app : l'écran verrouillé l'affiche sur la pochette floutée.
        let renderer = ImageRenderer(content: FallbackArt().frame(width: 600, height: 600).background(Theme.background).environment(\.colorScheme, .dark))
        renderer.scale = 1
        return renderer.uiImage
    }()

    /// Hors du thread principal : iOS demande l'image depuis n'importe quel thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
