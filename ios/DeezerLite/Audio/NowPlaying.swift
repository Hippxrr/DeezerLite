import MediaPlayer
import SwiftUI
import UIKit

/// Écran verrouillé et Centre de contrôle. Mis à jour seulement aux changements de titre et d'état :
/// iOS fait avancer la position seul grâce à `elapsedPlaybackTime` et `playbackRate`.
@MainActor
enum NowPlaying {
    private static var shownTrack: Int64?
    /// Adresse de la pochette affichée : une pochette réparée ou changée pendant l'écoute remplace l'ancienne (avant,
    /// l'ancienne restait jusqu'au titre suivant).
    private static var shownCover: String?
    /// Grande pochette déjà demandée pour le titre affiché.
    private static var sharpAsked = false
    /// Grande pochette (1000 px) déjà affichée.
    private static var sharpShown = false
    /// Téléchargement de la grande pochette raté : nouvel essai possible à partir de cet instant.
    private static var retryAt = Date.distantPast
    /// Essais ratés de la grande pochette pour le titre affiché (voir `requestSharp`).
    private static var sharpTries = 0
    private static var artwork: MPMediaItemArtwork?
    /// Position et vitesse envoyées en dernier, et quand.
    private static var sent: (elapsed: Double, rate: Double, at: Date) = (0, 0, .distantPast)

    /// iOS appelle ces commandes sur le thread principal.
    static func setup(_ player: Player) {
        let cc = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { event in MainActor.assumeIsolated { action(event) } }
        }
        // Rien à jouer (file vidée, lancement sans dernière écoute) : la commande est refusée. Avant, la session audio
        // était activée pour rien et coupait l'app qui jouait (podcast…).
        on(cc.playCommand) { _ in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.resume(); return .success
        }
        on(cc.pauseCommand) { _ in player.pause(); return .success }
        on(cc.togglePlayPauseCommand) { _ in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.toggle(); return .success
        }
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

    /// `cover` : pochette à montrer (celle choisie ici pour un MP3 importé, sinon celle du titre). `sharp` faux pendant une
    /// rafale de suivant / précédent : la grande pochette n'est demandée qu'au titre où l'on s'arrête (avant, une par titre
    /// sauté, sans pouvoir l'annuler).
    static func update(track: Track?, status: Status, cover: String?, sharp: Bool = true) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            shownTrack = nil
            shownCover = nil
            artwork = nil
            return
        }
        let loader = CoverLoader.shared
        if shownTrack != track.id || shownCover != cover {
            shownTrack = track.id
            shownCover = cover
            artwork = nil
            sharpAsked = false
            sharpShown = false
            retryAt = .distantPast
            sharpTries = 0
            if let url = cover {
                // Tout de suite : la grande si elle est prête (titre suivant préparé à l'avance), sinon la meilleure en mémoire.
                if let big = loader.cached(url: url, pixels: 1000) {
                    artwork = makeArtwork(big)
                    sharpShown = true
                } else if let ready = loader.anyCached(url: url) {
                    artwork = makeArtwork(ready)
                }
            } else if let fallback = fallbackImage {
                artwork = makeArtwork(fallback) // titre sans pochette : l'image de secours, comme dans l'app
            }
        }
        if sharp, !sharpShown, let url = cover {
            if let big = loader.cached(url: url, pixels: 1000) {
                // Grande pochette arrivée entre-temps (rafale de suivant, lecteur ouvert) : reprise tout de suite. Avant, elle
                // n'était jamais montrée et l'écran verrouillé restait sans pochette, ou flou, pour tout le titre.
                artwork = makeArtwork(big)
                sharpShown = true
            } else if !sharpAsked, Date() >= retryAt {
                // Puis la version nette (1000 px), une seule à la fois, remplacée au titre suivant.
                requestSharp(trackID: track.id, url: url)
            }
        }
        // Toujours rien à montrer, mais l'app a chargé cette pochette entre-temps (à une autre taille) : reprise tout de suite.
        if artwork == nil, let url = cover, let ready = loader.anyCached(url: url) { artwork = makeArtwork(ready) }
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

    /// Grande pochette (1000 px) téléchargée, puis posée sur l'écran verrouillé si le titre affiché n'a pas changé.
    private static func requestSharp(trackID: Int64, url: String) {
        sharpAsked = true
        Task {
            let image = await CoverLoader.shared.image(url: url, pixels: 1000)
            guard shownTrack == trackID, shownCover == url else { return }
            guard let image else {
                // Échec (réseau, serveur lent, app en arrière-plan) : nouvel essai tout seul 10 s plus tard, 3 essais au plus
                // par titre (et à toute mise à jour après ce délai). Avant, seule une mise à jour (pause, titre suivant) le
                // relançait : un titre commencé écran verrouillé restait sans pochette jusqu'au bout, puis la retrouvait à
                // l'ouverture de l'app.
                sharpAsked = false
                retryAt = Date().addingTimeInterval(10)
                sharpTries += 1
                guard sharpTries < 3 else { return }
                try? await Task.sleep(for: .seconds(10))
                if shownTrack == trackID, shownCover == url, !sharpShown, !sharpAsked { requestSharp(trackID: trackID, url: url) }
                return
            }
            artwork = makeArtwork(image)
            sharpShown = true
            let center = MPNowPlayingInfoCenter.default()
            guard var info = center.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            let elapsed = sent.elapsed + sent.rate * Date().timeIntervalSince(sent.at)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            sent = (elapsed, sent.rate, Date())
            center.nowPlayingInfo = info
        }
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
