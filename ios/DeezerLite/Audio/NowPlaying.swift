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
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { event in MainActor.assumeIsolated { action(event) } }
        }
        on(cc.playCommand) { _ in player.resume(); return .success }
        on(cc.pauseCommand) { _ in player.pause(); return .success }
        on(cc.togglePlayPauseCommand) { _ in player.toggle(); return .success }
        on(cc.nextTrackCommand) { _ in player.next(); return .success }
        on(cc.previousTrackCommand) { _ in player.previous(); return .success }
        on(cc.changePlaybackPositionCommand) { e in
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
        guard let track else {
            center.nowPlayingInfo = nil
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
        center.nowPlayingInfo = info
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
