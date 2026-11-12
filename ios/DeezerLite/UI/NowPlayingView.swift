import AVKit
import Observation
import SwiftUI

/// Glissement horizontal (mini-lecteur, grande pochette). Seul le modificateur qui applique le décalage le lit :
/// le contenu (pochettes, textes) n'est pas reconstruit à chaque mouvement du doigt.
@Observable
final class SlideState {
    var dx: CGFloat = 0
    @ObservationIgnored var axis: Axis?
    /// Deux dernières positions du doigt et leur moment : vitesse réelle au lâcher (voir `fingerVelocity`).
    @ObservationIgnored private var samples: [(x: CGFloat, t: TimeInterval)] = []

    func track(_ x: CGFloat) {
        samples.append((x, ProcessInfo.processInfo.systemUptime))
        if samples.count > 2 { samples.removeFirst() }
    }

    /// Vitesse du doigt sur ses deux derniers mouvements (points par seconde). Celle de `DragGesture` est lissée sur une
    /// période plus longue et sous-estime un lancer rapide : le ressort partait moins vite que le doigt, et la première
    /// image après le lâcher semblait freiner d'un coup. `fallback` si les mesures manquent ou sont trop anciennes.
    func fingerVelocity(fallback: CGFloat) -> CGFloat {
        defer { samples = [] }
        guard samples.count == 2 else { return fallback }
        let (a, b) = (samples[0], samples[1])
        let dt = b.t - a.t
        let age = ProcessInfo.processInfo.systemUptime - b.t
        guard dt > 0.002, dt < 0.05, age < 0.05 else { return fallback }
        return (b.x - a.x) / dt
    }

    /// Geste annulé par le système (appel, Centre de contrôle), donc sans `onEnded` : tout revient en place. Une fin
    /// normale a déjà remis `axis` à zéro, rien à faire alors.
    @MainActor func recover(_ done: (@MainActor () -> Void)? = nil) {
        Task { @MainActor in
            await Task.yield()
            guard axis != nil else { return }
            axis = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dx = 0 }
            done?()
        }
    }
}

struct SlideOffset: ViewModifier {
    let state: SlideState

    func body(content: Content) -> some View {
        content.offset(x: state.dx)
    }
}

/// Ressort doux qui part à la vitesse du doigt (`distance` = chemin restant jusqu'à l'arrivée).
/// `bounce: false` : amorti juste ce qu'il faut pour s'arrêter pile, sans dépasser (mini-lecteur).
func softSpring(distance: CGFloat, velocity: CGFloat, bounce: Bool = true, headStart: TimeInterval = 0) -> Animation {
    let relative = abs(distance) > 1 ? velocity / distance : 0
    let damping: Double = bounce ? 25 : 28
    guard headStart > 0 else { return .interpolatingSpring(mass: 1, stiffness: 190, damping: damping, initialVelocity: relative) }
    return Animation(HeadStartSpring(stiffness: 190, damping: damping, initialVelocity: relative, skip: headStart))
}

/// Ressort qui démarre `skip` secondes « en avance ». Au lâcher, le doigt a fait son dernier mouvement une image plus tôt
/// et un ressort normal commence immobile : l'image du lâcher restait figée, un petit accroc dans l'élan. Ici, la toute
/// première image est déjà là où l'élan l'aurait portée.
private struct HeadStartSpring: CustomAnimation {
    let stiffness: Double
    let damping: Double
    let initialVelocity: Double
    let skip: TimeInterval

    private var base: Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: damping, initialVelocity: initialVelocity)
    }

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        base.animate(value: value, time: time + skip, context: &context)
    }

    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
        base.velocity(value: value, time: time + skip, context: context)
    }

    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>) -> Bool {
        base.shouldMerge(previous: previous, value: value, time: time + skip, context: &context)
    }
}

/// Mini-lecteur flottant au-dessus des onglets ; appui = lecteur plein écran.
/// Glisser sur le titre : les titres voisins suivent le doigt, comme un carrousel.
struct MiniPlayer: View {
    @Environment(Player.self) private var player
    /// Dans la barre d'onglets : c'est iOS qui dessine la bulle, et la place est plus petite.
    var inBar = false
    /// Barre réduite, à côté des onglets : seulement la pochette, le titre et lecture / pause.
    var compact = false
    /// Réglages > Apparence : barre de progression en bas du mini-lecteur (affichée de base).
    @AppStorage("miniProgress") private var showProgress = true

    init(inBar: Bool = false, compact: Bool = false) {
        self.inBar = inBar
        self.compact = compact
    }

    private var row: some View {
        HStack(spacing: 8) {
            MiniCarousel(cover: inBar ? 34 : 44)
                .frame(height: inBar ? 40 : 46)
                .clipped()
            PlayButton(size: inBar ? 16 : 19)
            if let t = player.current, t.id != 0, !compact {
                // S'efface tout de suite : il ne suit pas le mini-lecteur qui rétrécit.
                LikeButton(track: t, size: inBar ? 16 : 18).frame(width: 36, height: 40)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
    }

    /// Collée au bas, même retrait des deux côtés, et découpée par la forme exacte de la bulle :
    /// elle ne peut pas déborder des coins arrondis, quel que soit leur dessin.
    @ViewBuilder
    private func progress<S: Shape>(_ shape: S) -> some View {
        if showProgress {
            progressLine(shape)
        }
    }

    private func progressLine<S: Shape>(_ shape: S) -> some View {
        ProgressLine(height: 2, track: .clear, fill: Theme.accent)
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    /// Un appui ouvre le grand lecteur, dans toute la forme de la bulle.
    private func opensPlayer<V: View, S: Shape>(_ view: V, _ shape: S) -> some View {
        view
            .contentShape(shape)
            .onTapGesture { player.showFullPlayer = true }
            .accessibilityAction(named: tr("Ouvrir le lecteur")) { player.showFullPlayer = true }
    }

    @ViewBuilder
    var body: some View {
        if inBar {
            opensPlayer(
                row
                    .padding(.horizontal, compact ? 8 : 12)
                    .frame(maxHeight: .infinity)
                    .overlay { progress(Capsule()) },
                Capsule()
            )
        } else {
            let bubble = RoundedRectangle(cornerRadius: 24, style: .continuous)
            opensPlayer(
                row
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    // Bulle flottante (verre qui réagit au doigt sur iOS 26).
                    .surface(bubble, material: true)
                    .overlay { progress(bubble) },
                bubble
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            // Un peu moins large que la barre d'onglets ; ces marges ne réagissent pas au doigt (la liste dessous, si).
            .padding(.horizontal, 30)
        }
    }

}

/// Titre du mini-lecteur qu'on fait glisser. À part du mini-lecteur : pendant le glissement, seul ce carrousel est
/// redessiné (avant, tout le mini-lecteur pouvait l'être à chaque mouvement du doigt : boutons, barre de progression…).
private struct MiniCarousel: View {
    @Environment(Player.self) private var player
    let cover: CGFloat
    @State private var slide = SlideState()
    /// Titres d'avance pris par le carrousel, transmis au lecteur une fois le geste posé (voir `CarouselSteps`).
    @State private var steps = CarouselSteps()
    /// Doigt posé : revient à `false` même si le système annule le geste, sans `onEnded`.
    @GestureState private var swiping = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            MiniStrip(width: width, steps: steps, cover: cover)
                .modifier(SlideOffset(state: slide))
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(swipe(width: width))
        }
        .onChange(of: swiping) { _, on in if !on { slide.recover { steps.settle(slide: slide, player: player) } } }
    }

    /// Avance du ressort au lâcher (voir `HeadStartSpring`), réglée sur la vidéo : à 0, l'image du lâcher restait figée ;
    /// à ~20 ms, la première image allait trop loin et la suivante presque pas (un autre accroc).
    private static let releaseHeadStart: TimeInterval = 0.01

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($swiping) { _, state, _ in state = true }
            .onChanged { v in
                if slide.axis == nil {
                    steps.interrupt(slide: slide)
                    slide.axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                guard slide.axis == .horizontal else { return }
                let base = steps.base(player)
                let blocked = (v.translation.width < 0 && !player.queue.indices.contains(base + 1))
                    || (v.translation.width > 0 && !player.queue.indices.contains(base - 1))
                slide.dx = blocked ? v.translation.width * 0.25 : v.translation.width
                slide.track(slide.dx)
            }
            .onEnded { v in
                let horizontal = slide.axis == .horizontal
                slide.axis = nil
                guard horizontal else { return }
                let base = steps.base(player)
                let fling = v.predictedEndTranslation.width
                let forward = fling < -width * 0.35 && player.queue.indices.contains(base + 1)
                let backward = fling > width * 0.35 && player.queue.indices.contains(base - 1)
                steps.land(delta: forward ? 1 : backward ? -1 : 0, distance: width + MiniStrip.gap,
                           velocity: slide.fingerVelocity(fallback: v.velocity.width),
                           bounce: false, headStart: Self.releaseHeadStart, waitFullStop: true, slide: slide, player: player)
            }
    }
}

#if compiler(>=6.2.1)
/// Mini-lecteur dans la barre d'onglets : plus compact quand la barre est réduite.
@available(iOS 26.1, *)
struct BarMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayer(inBar: true, compact: placement == .inline)
    }
}
#endif

/// Titres d'avance pris par un carrousel. Au lâcher, seul le carrousel avance (le voisin prend la place exacte
/// du titre en cours) ; le lecteur n'est prévenu qu'une fois le titre arrivé à sa place (fin de l'animation), en un
/// seul saut même après plusieurs glissements. Avant, il l'était 0,3 s après le lâcher, en plein milieu de l'arrivée
/// du titre suivant : le changement de titre (chargement, listes, lecteur, écran verrouillé) saccadait sa fin de course.
@Observable
final class CarouselSteps {
    var pending = 0
    @ObservationIgnored private var flush: Task<Void, Never>?

    @MainActor func base(_ player: Player) -> Int { player.shownIndex + pending }

    /// Titre affiché au centre du carrousel.
    @MainActor func current(_ player: Player) -> Track? {
        guard pending != 0 else { return player.current }
        let i = base(player)
        return player.queue.indices.contains(i) ? player.queue[i] : player.current
    }

    @MainActor func neighbor(_ player: Player, _ offset: Int) -> Track? {
        let i = base(player) + offset
        return player.queue.indices.contains(i) ? player.queue[i] : nil
    }

    /// Arrivée en cours vers un titre voisin (-1, 0 ou 1), pas encore prise en compte dans `pending`.
    @ObservationIgnored private var landing = 0
    /// Change à chaque arrivée : la fin d'une ancienne animation (interrompue) ne valide pas la nouvelle.
    @ObservationIgnored private var landingID = 0

    /// Au lâcher : le carrousel glisse jusqu'au titre voisin (`delta` = ±1) ou revient en place (0), à la vitesse du doigt.
    /// Les titres affichés ne changent qu'une fois arrivé, d'un coup et sans animation (à cet instant, l'image est
    /// identique). Avant, ils changeaient au lâcher, pendant le ressort : la pochette du titre suivant prenait un autre
    /// trajet que son texte et passait dessous.
    /// `waitFullStop` : échange des titres une fois le ressort tout à fait arrêté (mini-lecteur : à « presque fini », la fin
    /// du trajet sautait de 2 à 3 points) ; sinon dès qu'il est presque arrivé, et le son suit aussitôt (grand lecteur, où
    /// l'attente avant le son se sentait).
    @MainActor func land(delta: Int, distance: CGFloat, velocity: CGFloat, bounce: Bool = true, headStart: TimeInterval = 0,
                         waitFullStop: Bool = false, slide: SlideState, player: Player) {
        landingID += 1
        let id = landingID
        landing = delta
        let target: CGFloat = delta == 0 ? 0 : delta > 0 ? -distance : distance
        withAnimation(softSpring(distance: target - slide.dx, velocity: velocity, bounce: bounce, headStart: headStart),
                      completionCriteria: waitFullStop ? .removed : .logicallyComplete) {
            slide.dx = target
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, id == self.landingID else { return }
                self.commitLanding(slide: slide)
                self.schedule(slide: slide, player: player, after: .milliseconds(waitFullStop ? 80 : 0))
            }
        }
        // Filet de sécurité si la fin d'animation n'arrive jamais (vue retirée…) : l'arrivée est validée quand même, sinon
        // le swipe était perdu (le lecteur n'était prévenu que de ce qui était déjà validé).
        if delta != 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, id == self.landingID, self.landing != 0, slide.axis == nil else { return }
                self.landingID += 1
                self.commitLanding(slide: slide)
                self.schedule(slide: slide, player: player, after: .zero)
            }
        }
    }

    /// Nouveau glissement commencé pendant une arrivée : celle-ci est validée tout de suite.
    @MainActor func interrupt(slide: SlideState) {
        landingID += 1
        commitLanding(slide: slide)
    }

    /// Titre voisin arrivé au centre : il devient le titre affiché et le carrousel revient à zéro (même image à l'écran).
    @MainActor private func commitLanding(slide: SlideState) {
        guard landing != 0 else { return }
        let delta = landing
        landing = 0
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            pending += delta
            slide.dx = 0
        }
    }

    /// Geste annulé par le système : rien de pris n'est perdu.
    @MainActor func settle(slide: SlideState, player: Player) {
        schedule(slide: slide, player: player, after: .milliseconds(450))
    }

    /// Prévient le lecteur, sauf si un nouveau glissement a commencé (sa fin s'en chargera).
    @MainActor private func schedule(slide: SlideState, player: Player, after delay: Duration) {
        flush?.cancel()
        flush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.pending != 0, slide.axis == nil else { return }
            let k = self.pending
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                self.pending = 0
                player.step(k)
            }
        }
    }
}

/// Titre précédent, en cours et suivant côte à côte (le précédent hors champ à gauche).
private struct MiniStrip: View {
    static let gap: CGFloat = 40
    @Environment(Player.self) private var player
    let width: CGFloat
    let steps: CarouselSteps
    let cover: CGFloat

    var body: some View {
        // Voisins écartés d'un vide : la fin d'un glissement ne laisse jamais voir le bord de la pochette suivante.
        HStack(spacing: Self.gap) {
            MiniInfo(track: steps.neighbor(player, -1), placeholder: "", side: cover).frame(width: width).accessibilityHidden(true)
            MiniInfo(track: steps.current(player), placeholder: tr("Chargement…"), side: cover).frame(width: width)
            MiniInfo(track: steps.neighbor(player, 1), placeholder: "", side: cover).frame(width: width).accessibilityHidden(true)
        }
        .offset(x: -(width + Self.gap))
    }
}

private struct MiniInfo: View {
    let track: Track?
    let placeholder: String
    let side: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            if track != nil || !placeholder.isEmpty {
                if let track {
                    // Identité liée à la pochette : jamais l'image du titre d'avant pendant une image.
                    CoverView(url: track.coverUrl, side: side, radius: 8).id(track.coverUrl ?? "")
                } else {
                    // Chargement : pas de pochette (ni celle de remplacement), juste sa place pour que le texte ne bouge pas.
                    Color.clear.frame(width: side, height: side)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? placeholder).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track?.artist ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// Flèche suivant / précédent grisée et inactive quand il n'y a pas de titre de ce côté.
    func skipEnabled(_ enabled: Bool) -> some View {
        disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
}

/// Progression continue : position relue 2 fois par seconde, et la barre glisse en ligne droite entre deux lectures
/// (animation du système, aucune minuterie à 60 images par seconde). Arrêtée en pause et quand elle est cachée.
struct ProgressLine: View {
    @Environment(Player.self) private var player
    let height: CGFloat
    let track: Color
    let fill: Color

    var body: some View {
        // Toujours à jour, même cachée (2 lectures par seconde) : en passant du grand lecteur au mini, la barre est
        // déjà à la bonne place au lieu de « rattraper ». Nouveau titre : nouvelle barre, sans glissement depuis l'ancien.
        TimelineView(.animation(minimumInterval: 0.5, paused: !player.status.playing)) { ctx in
            let total = max(Double(player.status.durationMs) / 1000, 1)
            let fraction = min(max(player.position(at: ctx.date) / total, 0), 1)
            ZStack(alignment: .leading) {
                track
                // Pendant la lecture, la barre avance par petits pas (moins d'un point toutes les 0,5 s), sans animation :
                // avec un glissement continu entre deux pas, elle était redessinée à chaque image, en permanence, et avec
                // elle tout le verre du mini-lecteur, ce qui ralentissait le glissement des titres et le défilement.
                fill.scaleEffect(x: fraction, anchor: .leading)
                    .animation(player.status.playing ? nil : .easeOut(duration: 0.2), value: fraction)
            }
            .frame(height: height)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .id(player.current?.id)
    }
}

/// Lecture / pause : changement d'icône animé, indicateur pendant le chargement.
struct PlayButton: View {
    @Environment(Player.self) private var player
    let size: CGFloat
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            player.toggle()
        } label: {
            ZStack {
                if player.loading {
                    ProgressView().controlSize(size > 30 ? .large : .regular).tint(.primary)
                } else {
                    Image(systemName: player.status.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size * 2, height: size * 2)
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

/// Cœur « J'aime » : animé, avec une petite vibration à l'ajout.
struct LikeButton: View {
    @Environment(Player.self) private var player
    let track: Track
    let size: CGFloat
    /// Ajouts faits par un appui : seul cela déclenche le rebond et la vibration (pas l'arrivée sur un titre aimé).
    @State private var likes = 0
    /// Retirer des titres aimés se confirme (ajouter, non).
    @State private var confirmUnlike = false

    var body: some View {
        let liked = player.lovedIds.contains(track.id)
        Button {
            if liked {
                confirmUnlike = true
            } else {
                likes += 1
                player.setLiked(track, true)
            }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size))
                .foregroundStyle(liked ? Theme.accent : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: likes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.success, trigger: likes)
        .confirmationDialog(tr("Retirer « %@ » de « %@ » ?", track.title, player.lovedTitle), isPresented: $confirmUnlike, titleVisibility: .visible) {
            Button(tr("Retirer"), role: .destructive) { player.setLiked(track, false) }
        }
    }
}

// MARK: - Lecteur plein écran

/// Position verticale du lecteur plein écran (0 = ouvert, `height` = caché sous l'écran).
/// Objet à part : seul le conteneur lit `y`, le contenu du lecteur n'est pas redessiné pendant le geste.
@Observable
final class PullState {
    var y: CGFloat = 100_000 // hors de l'écran tant que la hauteur n'est pas connue
    @ObservationIgnored var height: CGFloat = 1000
    /// Position visée par l'animation en cours.
    @ObservationIgnored var target: CGFloat = 100_000

    /// Geste annulé par le système alors que le lecteur était tiré vers le bas : il revient en place. Après une fin
    /// normale, `y` vaut déjà sa position finale et il n'y a rien à faire.
    @MainActor func recover() {
        Task { @MainActor in
            await Task.yield()
            if y > 0, target == 0 { settle(open: true) }
        }
    }

    /// Ressort qui part à la vitesse du doigt : ni arrêt au lâcher, ni à-coup au retour.
    func settle(open: Bool, velocity: CGFloat = 0, done: (() -> Void)? = nil) {
        target = open ? 0 : height
        let distance = target - y
        let relative = abs(distance) > 1 ? velocity / distance : 0
        // Fermeture rapide et sans rebond, qui garde l'élan du doigt jusqu'en bas.
        let spring: Animation = open
            ? .interpolatingSpring(mass: 1, stiffness: 300, damping: 34, initialVelocity: relative)
            : .interpolatingSpring(mass: 1, stiffness: 420, damping: 41, initialVelocity: relative)
        withAnimation(spring) { y = target } completion: { done?() }
    }
}

/// Conteneur du lecteur plein écran, toujours en place (caché sous l'écran quand il est fermé) :
/// l'ouvrir ou le fermer n'est qu'un déplacement, rien n'est construit au moment de l'animation.
struct FullPlayerContainer: View {
    @Environment(Player.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var pull = PullState()

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            // En arrière-plan, le lecteur fermé est retiré (sa grande pochette ne reste pas en mémoire) ;
            // ouvert, il reste : l'aperçu du sélecteur d'apps montre ce qui était vraiment à l'écran.
            if scenePhase != .background || player.showFullPlayer {
                NowPlayingView(pull: pull)
                    // Toujours en sombre, quel que soit le mode : son fond est la pochette assombrie (comme Apple Music).
                    .environment(\.colorScheme, .dark)
                    .offset(y: pull.y)
                    .allowsHitTesting(player.showFullPlayer)
                    .accessibilityHidden(!player.showFullPlayer)
                    .onAppear { place(height) }
                    .onChange(of: height) { _, h in place(h) }
            }
        }
        .onChange(of: player.showFullPlayer) { _, open in
            // Ouverture par le mini-lecteur, fermeture par la flèche ou une navigation ; le geste lance déjà le sien.
            if pull.target != (open ? 0 : pull.height) { pull.settle(open: open) }
        }
    }

    private func place(_ height: CGFloat) {
        pull.height = height
        if !player.showFullPlayer {
            pull.y = height
            pull.target = height
        }
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    let pull: PullState
    /// Grande pochette, ou à sa place la file d'attente ou les paroles (comme dans Apple Music).
    enum Panel { case cover, queue, lyrics }
    @State private var panel: Panel = .cover
    @State private var showPlaylists = false
    /// Mode épuré (appui long sur la pochette) : seuls la pochette, le titre, l'artiste et la barre restent.
    @State private var clean = false
    /// Doigt posé sur le lecteur : revient à `false` même si le système annule le geste, sans `onEnded`.
    @GestureState private var pulling = false
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, geo.size.height * 0.42)
            VStack(spacing: 0) {
                Color.clear.frame(height: 21) // marge du haut (le lecteur se ferme en le tirant vers le bas)
                if panel != .cover {
                    compactHeader
                        .transition(.opacity)
                    Group {
                        if panel == .queue { QueuePanel() } else { LyricsPanel() }
                    }
                    .transition(.opacity)
                } else {
                    Spacer(minLength: 8)
                    CoverCarousel(side: side, width: geo.size.width, pull: pull, onPullEnd: pullEnded) { clean.toggle() }
                        .transition(.opacity)
                    Spacer(minLength: 8)
                    titleRow
                        .legible()
                        .padding(.bottom, 18)
                }
                VStack(spacing: 18) {
                    ScrubBar().id("\(player.current?.id ?? 0)|\(player.showFullPlayer)")
                    // Masqués sans changer la mise en page : la pochette et le titre ne bougent pas.
                    Group {
                        controls
                        bottomRow
                    }
                    .opacity(clean ? 0 : 1)
                    .allowsHitTesting(!clean)
                }
                .legible()
                .padding(.top, panel == .cover ? 0 : 12)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 4)
            .animation(.easeInOut(duration: 0.3), value: panel)
            .animation(.easeInOut(duration: 0.3), value: clean)
        }
        // Retour haptique à l'appui long seulement (pas à la remise en mode normal quand le lecteur se ferme).
        .sensoryFeedback(trigger: clean) { _, _ in player.showFullPlayer ? .impact(weight: .medium) : nil }
        // Lecteur fermé : il se rouvre toujours en mode normal.
        .onChange(of: player.showFullPlayer) { _, open in if !open { clean = false } }
        .foregroundStyle(.white)
        .background { Backdrop(url: player.current?.coverUrl, open: player.showFullPlayer) }
        .contentShape(Rectangle())
        // File ou paroles ouvertes : le geste est coupé pour laisser défiler la liste.
        .gesture(pullGesture, including: panel == .cover ? .all : .subviews)
        .onChange(of: pulling) { _, on in if !on { pull.recover() } }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { player.showFullPlayer = false }
    }

    /// Glissement vertical n'importe où sur le lecteur : tout le lecteur descend.
    /// Mesuré dans le repère de l'écran : le lecteur qui bouge ne fausse pas la mesure.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($pulling) { _, state, _ in state = true }
            .onChanged { v in
                guard v.translation.height > abs(v.translation.width) || pull.y > 0 else { return }
                pull.y = max(0, v.translation.height)
            }
            .onEnded { v in
                guard pull.y > 0 else { return }
                pullEnded(v)
            }
    }

    private func pullEnded(_ v: DragGesture.Value) {
        let close = v.translation.height > 140 || v.predictedEndTranslation.height > 260 || v.velocity.height > 800
        // Le ressort repart à la vitesse du doigt, dans un sens comme dans l'autre. À la fermeture, le reste de l'app
        // (mini-lecteur, pochettes, barres) n'est mis à jour qu'une fois le lecteur arrivé en bas : rien ne pèse
        // sur l'animation.
        if close {
            pull.settle(open: false, velocity: v.velocity.height) {
                // Rattrapé puis relâché vers le haut entre-temps : le lecteur reste ouvert.
                if pull.target == pull.height { player.showFullPlayer = false }
            }
        } else {
            pull.settle(open: true, velocity: v.velocity.height)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // Titre trop long : réduit pour tenir sur la ligne, plutôt que coupé par « … ».
                Text(player.current?.title ?? "").font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.5)
                if let t = player.current {
                    // Appui sur l'artiste : choisir lequel ouvrir (tous ceux d'un feat), ou l'album.
                    Menu {
                        ForEach(t.artistLinks, id: \.id) { a in
                            Button { player.navigate(.detail(kind: "artist", id: a.id, title: a.name)) } label: { Label(a.name, systemImage: "music.mic") }
                        }
                        if t.albumId != 0 {
                            Button { player.navigate(.detail(kind: "album", id: t.albumId, title: t.album)) } label: { Label(t.album, systemImage: "square.stack") }
                        }
                        Divider()
                        Button { player.creditsTrack = t } label: { Label(tr("Voir les crédits"), systemImage: "person.2") }
                        ShareTrackButton(track: t)
                    } label: {
                        Text(t.artist).font(.title3).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            .id(player.current?.id)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            // « + » et cœur masqués en mode épuré.
            trackButtons(size: 22, plus: !clean, heart: !clean)
                .allowsHitTesting(!clean)
        }
        .animation(.easeOut(duration: 0.25), value: player.current?.id)
    }

    /// En-tête réduit quand la file d'attente ou les paroles sont ouvertes. Un appui sur la petite pochette ou sur le
    /// titre ferme le panneau et revient à la pochette en grand (le « + » et le cœur gardent leur propre action).
    private var compactHeader: some View {
        HStack(spacing: 14) {
            Button { panel = .cover } label: {
                HStack(spacing: 14) {
                    CoverView(url: player.current?.coverUrl, side: 64, radius: 8)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "").font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                        Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Toute la zone réagit, espace vide à droite du titre compris.
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityHint(tr("Revient à la pochette"))
            trackButtons(size: 20, plus: true, heart: true)
        }
        .padding(.bottom, 14)
    }

    /// « + » (petite bulle de playlists, accrochée au bouton) et cœur.
    @ViewBuilder
    private func trackButtons(size: CGFloat, plus: Bool, heart: Bool) -> some View {
        if let t = player.current {
            Button { showPlaylists = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: size + 4))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.pressable)
            .popover(isPresented: $showPlaylists, arrowEdge: .bottom) {
                PlaylistPicker(track: t) { showPlaylists = false }
                    .environment(player)
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
            }
            .opacity(plus ? 1 : 0)
            LikeButton(track: t, size: size).frame(width: 40, height: 44)
                .opacity(heart ? 1 : 0)
        }
    }

    /// Mode de répétition lu par VoiceOver (« Répéter » éteint et « Répéter la file » ont la même icône).
    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: tr("Répéter : désactivé")
        case .all: tr("Répéter la file")
        case .one: tr("Répéter le titre")
        }
    }

    private var controls: some View {
        HStack {
            // Flow : file sans fin, répéter ou mélanger n'a pas de sens (place gardée pour ne pas décaler les boutons).
            if player.isFlow {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.5) : Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(repeatLabel)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32)).frame(width: 64, height: 64)
            }
            .skipEnabled(player.hasPrevious)
            Spacer()
            PlayButton(size: 40)
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 64, height: 64)
            }
            .skipEnabled(player.hasNext)
            Spacer()
            if player.isFlow {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button { player.toggleShuffle() } label: {
                    ShuffleIcon(on: player.shuffle)
                        .accessibilityLabel(player.shuffle ? tr("Aléatoire : activé") : tr("Aléatoire : désactivé"))
                        .foregroundStyle(player.shuffle ? Theme.accent : Color.white)
                        .opacity(player.shuffle ? 1 : 0.5)
                        .animation(.easeOut(duration: 0.2), value: player.shuffle)
                        .frame(width: 44, height: 44)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: player.shuffle)
            }
        }
        .buttonStyle(.pressable)
    }

    private var bottomRow: some View {
        HStack {
            panelButton(.lyrics, icon: "quote.bubble")
            Spacer()
            SoundMenuButton()
            Spacer()
            panelButton(.queue, icon: "list.bullet")
        }
        .padding(.horizontal, 20)
    }

    /// Paroles / file : un appui ouvre le panneau, un second revient à la pochette.
    private func panelButton(_ target: Panel, icon: String) -> some View {
        let on = panel == target
        return Button { panel = on ? .cover : target } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Color.white.opacity(0.75))
                .frame(width: 44, height: 44)
                .background {
                    if on { Color.clear.surface(RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: false, material: true) }
                }
        }
        .buttonStyle(.pressable)
    }
}

extension Track {
    /// Artistes proposés par « Aller à l'artiste » : tous ceux d'un feat, sinon l'artiste principal.
    var artistLinks: [ArtistRef] {
        if !artists.isEmpty { return artists }
        return artistId != 0 ? [ArtistRef(id: artistId, name: artist)] : []
    }
}

/// Fond du lecteur : la pochette floutée en bonne qualité (voir `CoverLoader.backdrop`), assombrie pour le texte.
/// Rien n'est calculé en arrière-plan : le fond est fait (ou refait) au retour dans l'app.
private struct Backdrop: View {
    let url: String?
    /// Lecteur fermé : fond fait seulement à partir de la pochette déjà en mémoire, sans téléchargement.
    let open: Bool
    @Environment(\.scenePhase) private var phase
    /// Fond précédent (dessous) et nouveau (dessus, qui apparaît en fondu) : d'une pochette à l'autre, jamais de
    /// passage par le noir, et un fondu long pour adoucir un passage clair → sombre.
    @State private var below: UIImage?
    @State private var top: UIImage?
    @State private var topOpacity: Double = 1
    /// Les fonds de pochette, ensemble : 0 = fond noir (titre sans pochette, ou pochette introuvable).
    @State private var shown: Double = 1
    /// Début du dernier fondu : une image qui arrive pendant un fondu ne fait pas sauter l'affichage.
    @State private var fadeStart = Date.distantPast

    var body: some View {
        ZStack {
            Color.black
            ZStack {
                if let below { layer(below) }
                if let top { layer(top).opacity(topOpacity) }
            }
            .opacity(shown)
            // Voile sombre : les couleurs restent présentes mais les écarts de clarté sont atténués.
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .task(id: "\(url ?? "")|\(phase == .background)|\(open)") {
            guard phase != .background else { return }
            // Titre sans pochette (image de secours) : fondu vers le noir.
            guard let url else { fadeToBlack(); return }
            guard let img = await CoverLoader.shared.backdrop(url: url, download: open) else {
                // Lecteur fermé et pochette pas encore en mémoire : le fond sera fait à l'ouverture.
                if open { fadeToBlack() }
                return
            }
            guard img !== top || shown < 1 else { return }
            if shown < 1 {
                // Depuis le noir : la nouvelle pochette apparaît seule, aucun ancien fond dessous.
                below = nil
                top = img
                topOpacity = 1
                withAnimation(.easeInOut(duration: 0.9)) { shown = 1 }
                return
            }
            // Fondu précédent terminé : l'image affichée passe dessous. Encore en cours : le dessous ne change pas
            // (l'image à moitié apparue serait sinon posée d'un coup en entier).
            if Date().timeIntervalSince(fadeStart) >= 1.1, let top, topOpacity > 0 { below = top }
            top = img
            topOpacity = 0
            fadeStart = Date()
            withAnimation(.easeInOut(duration: 1.1)) { topOpacity = 1 }
        }
    }

    /// Fondu vers le noir, puis les anciens fonds sont oubliés (jamais réaffichés sous un autre titre).
    private func fadeToBlack() {
        guard shown > 0 else { return }
        withAnimation(.easeInOut(duration: 0.9)) { shown = 0 } completion: {
            guard shown == 0 else { return } // une pochette est revenue entre-temps
            below = nil
            top = nil
        }
    }

    private func layer(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .saturation(1.15)
    }
}

/// Grande pochette en carrousel : les pochettes voisines suivent le doigt, puis la nouvelle se cale au centre
/// avec l'élan du geste. Vers le bas : ferme le lecteur. Le décalage est appliqué par `SlideOffset` :
/// les pochettes ne sont pas reconstruites pendant le geste.
private struct CoverCarousel: View {
    @Environment(Player.self) private var player
    let side: CGFloat
    /// Largeur de l'écran : les voisines restent hors champ au repos.
    let width: CGFloat
    let pull: PullState
    let onPullEnd: (DragGesture.Value) -> Void
    /// Appui long : mode épuré du lecteur.
    let onLongPress: () -> Void
    @State private var slide = SlideState()
    /// Doigt posé : revient à `false` même si le système annule le geste, sans `onEnded`.
    @GestureState private var dragging = false
    @State private var steps = CarouselSteps()

    private var step: CGFloat { (width + side) / 2 + 12 }

    var body: some View {
        let previous = steps.neighbor(player, -1)
        let next = steps.neighbor(player, 1)
        let current = steps.current(player)
        let active = player.status.playing || player.loading
        let open = player.showFullPlayer
        ZStack {
            // Chaque pochette a l'identité de son image : rien d'ancien ne s'affiche quand les voisines changent.
            if let previous { CoverView(url: previous.coverUrl, side: side, radius: 14, load: open).id(previous.coverUrl ?? "").offset(x: -step) }
            if let next { CoverView(url: next.coverUrl, side: side, radius: 14, load: open).id(next.coverUrl ?? "").offset(x: step) }
            // Lecteur fermé : pas de téléchargement de la grande pochette à chaque titre.
            CoverView(url: current?.coverUrl, side: side, radius: 14, load: open)
                .id(current?.coverUrl ?? "")
                .shadow(color: .black.opacity(0.4), radius: active ? 24 : 12, y: active ? 14 : 6)
                // Pochette réduite en pause, pleine taille en lecture (comme Apple Music).
                .scaleEffect(active ? 1 : 0.8)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: active)
        }
        .modifier(SlideOffset(state: slide))
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Annulé dès que le doigt glisse : le défilement des pochettes et le geste de fermeture restent prioritaires.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress() })
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { v in
                    if slide.axis == nil {
                    steps.interrupt(slide: slide)
                    slide.axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                    if slide.axis == .vertical {
                        pull.y = max(0, v.translation.height)
                    } else {
                        // Pas de voisine de ce côté : résistance élastique.
                        let blocked = (v.translation.width > 0 && steps.neighbor(player, -1) == nil)
                            || (v.translation.width < 0 && steps.neighbor(player, 1) == nil)
                        slide.dx = blocked ? v.translation.width * 0.3 : v.translation.width
                    }
                }
                .onEnded { v in
                    let vertical = slide.axis == .vertical
                    slide.axis = nil
                    if vertical { onPullEnd(v); return }
                    let fling = v.predictedEndTranslation.width
                    let forward = fling < -side * 0.35 && steps.neighbor(player, 1) != nil
                    let backward = fling > side * 0.35 && steps.neighbor(player, -1) != nil
                    steps.land(delta: forward ? 1 : backward ? -1 : 0, distance: step, velocity: v.velocity.width,
                               slide: slide, player: player)
                }
        )
        .onChange(of: dragging) { _, on in
            if !on { slide.recover { pull.recover(); steps.settle(slide: slide, player: player) } }
        }
    }
}

/// Barre de progression : fine au repos, plus épaisse sous le doigt ; le saut n'est envoyé qu'au lâcher.
/// Elle glisse en continu (voir `ProgressLine`) au lieu d'avancer seconde par seconde ; lecteur fermé, elle ne tourne
/// pas (elle est refaite à l'ouverture, directement à la bonne position).
struct ScrubBar: View {
    @Environment(Player.self) private var player
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: dragging != nil || !player.status.playing || !player.showFullPlayer)) { ctx in
            let total = max(Double(player.status.durationMs) / 1000, 1)
            let shown = min(dragging ?? player.position(at: ctx.date), total)
            let fraction = min(max(shown / total, 0), 1)
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.22)
                        Color.white.opacity(dragging == nil ? 0.85 : 1)
                            .scaleEffect(x: fraction, anchor: .leading)
                            .animation(dragging == nil && player.status.playing ? .linear(duration: 0.5) : nil, value: fraction)
                    }
                    .frame(height: dragging == nil ? 6 : 11)
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in dragging = min(max(v.location.x / geo.size.width, 0), 1) * total }
                            .onEnded { _ in
                                if let d = dragging { player.seek(seconds: d) }
                                dragging = nil
                            }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging == nil)
                }
                .frame(height: 24)
                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-" + formatTime(total - shown))
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(dragging == nil ? 0.55 : 0.9))
            }
        }
        .sensoryFeedback(.selection, trigger: dragging == nil)
        .accessibilityElement()
        .accessibilityLabel(tr("Position"))
        .accessibilityValue(tr("%@ sur %@", formatTime(player.position(at: .now)), formatTime(Double(player.status.durationMs) / 1000)))
        .accessibilityAdjustableAction { dir in
            let total = Double(player.status.durationMs) / 1000
            let target = player.position(at: .now) + (dir == .increment ? 15 : -15)
            player.seek(seconds: min(max(target, 0), max(total - 1, 0)))
        }
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Bouton « Son » du lecteur : petite bulle avec la sortie audio (AirPlay, Bluetooth…) et l'égaliseur,
/// pour changer de mode en pleine écoute.
private struct SoundMenuButton: View {
    @Environment(Player.self) private var player
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(player.eqPreset == .off ? Color.white.opacity(0.75) : Theme.accent)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SoundMenu()
                .environment(player)
                .presentationCompactAdaptation(.popover)
                .preferredColorScheme(.dark)
        }
    }
}

private struct SoundMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sortie audio : toute la ligne ouvre le choix d'iOS (le bouton système, invisible, la recouvre).
            HStack(spacing: 12) {
                Image(systemName: "airplayaudio").foregroundStyle(Theme.accent).frame(width: 24)
                Text(tr("Sortie audio"))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay { AirPlayButton().opacity(0.02) }
            Divider()
            // Égaliseur : interrupteur, puis le préréglage avec des flèches (comme dans Réglages > Son) ; deux lignes
            // au lieu de la liste des 15 préréglages. Les curseurs sont dans Réglages > Son.
            Toggle(isOn: Binding(get: { player.eqPreset != .off }, set: { on in withAnimation(.easeOut(duration: 0.15)) { player.setEqOn(on) } })) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.vertical.3").foregroundStyle(Theme.accent).frame(width: 24)
                    Text(tr("Égaliseur"))
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if player.eqPreset != .off {
                HStack(spacing: 0) {
                    Button { player.stepEqPreset(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        Image(systemName: player.eqPreset.icon).foregroundStyle(Theme.accent)
                        Text(player.eqPreset.name).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    Button { player.stepEqPreset(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.15), value: player.eqPreset)
                .transition(.opacity)
            }
        }
        .frame(width: 280)
        .sensoryFeedback(.selection, trigger: player.eqPreset)
    }
}

/// Petite bulle accrochée au « + » : un appui ajoute le titre à la playlist.
private struct PlaylistPicker: View {
    @Environment(Player.self) private var player
    let track: Track
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Ajouter à une playlist")).font(.subheadline.weight(.semibold)).padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if player.library[0] == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(20)
                    } else if player.ownedPlaylists.isEmpty {
                        Text(tr("Tu n'as pas encore créé de playlist.")).font(.footnote).foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(player.ownedPlaylists, id: \.id) { card in
                        Button {
                            player.addToPlaylist(card, track)
                            done()
                        } label: {
                            HStack(spacing: 10) {
                                CoverView(url: player.coverURL(card), side: 36, radius: 6)
                                Text(card.title).font(.subheadline).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
        .frame(width: 270, height: min(80 + CGFloat(max(player.ownedPlaylists.count, 1)) * 50, 340))
        .task { await player.loadLibrary(0, force: false) }
    }
}

/// File d'attente dans le lecteur : appui = lire ; glisser à gauche = retirer ; « Modifier » = réordonner.
private struct QueuePanel: View {
    @Environment(Player.self) private var player
    @State private var editing = false

    /// Une ligne de la file. Identité : le titre et sa nième apparition (un même titre peut y être deux fois). Repérée
    /// par sa position, une ligne retirée animait la dernière, et un menu ouvert passait sur le titre voisin.
    private struct Row: Identifiable {
        let id: String
        let index: Int
    }

    private func rows(from start: Int) -> [Row] {
        var seen: [Int64: Int] = [:]
        return (start..<player.queue.count).map { i in
            let track = player.queue[i].id
            let nth = seen[track, default: 0]
            seen[track] = nth + 1
            return Row(id: "\(track)-\(nth)", index: i)
        }
    }

    var body: some View {
        let start = min(player.queueIndex + 1, player.queue.count)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("À suivre")).font(.headline)
                if player.queue.count > start {
                    Text("\(player.queue.count - start)").font(.subheadline).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button(editing ? "OK" : tr("Modifier")) { withAnimation { editing.toggle() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if start >= player.queue.count {
                Text(tr("Rien d'autre dans la file.")).font(.subheadline).foregroundStyle(.white.opacity(0.55)).padding(.top, 20)
                Spacer()
            } else {
                List {
                    ForEach(rows(from: start)) { row in
                        let i = row.index
                        let t = player.queue[i]
                        Button { player.queuePlay(i) } label: {
                            HStack(spacing: 12) {
                                CoverView(url: t.coverUrl, side: 44, radius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(t.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { player.queueRemove(i) } label: { Label(tr("Retirer"), systemImage: "trash") }
                        }
                    }
                    .onMove { from, to in
                        guard let f = from.first else { return }
                        let source = start + f
                        let target = start + to
                        player.queueMove(from: source, to: target > source ? target - 1 : target)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(editing ? .active : .inactive))
            }
        }
    }
}

/// Paroles Deezer dans le lecteur : la ligne en cours est mise en avant et reste au centre ;
/// un appui sur une ligne y amène la lecture. Paroles non synchronisées : simple texte.
private struct LyricsPanel: View {
    @Environment(Player.self) private var player
    @State private var lyrics: Lyrics?
    @State private var loaded = false
    /// Ligne en cours (-1 : avant la première).
    @State private var active = -1
    /// Jusqu'à quand le texte ne suit plus la ligne en cours (l'utilisateur le fait défiler).
    @State private var readingUntil = Date.distantPast

    var body: some View {
        Group {
            if !loaded {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(lyrics.lines.indices, id: \.self) { i in
                                let line = lyrics.lines[i]
                                Text(line.text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.text)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white.opacity(!lyrics.synced || i == active ? 1 : 0.35))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard lyrics.synced else { return }
                                        player.seek(seconds: Double(line.ms) / 1000)
                                        active = i
                                    }
                                    .id(i)
                            }
                            if !lyrics.copyright.isEmpty {
                                Text(lyrics.copyright).font(.caption).foregroundStyle(.white.opacity(0.4)).padding(.top, 12)
                            }
                        }
                        .padding(.vertical, 24)
                    }
                    // Texte déplacé à la main : le suivi reprend 4 s après (on peut lire la suite tranquillement).
                    .modifier(ScrollWatch { reading in
                        readingUntil = reading ? .distantFuture : Date().addingTimeInterval(4)
                    })
                    .onChange(of: active) { _, i in
                        guard i >= 0, Date() >= readingUntil else { return }
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
                .animation(.easeOut(duration: 0.3), value: active)
                .background {
                    if lyrics.synced { LyricsClock(lines: lyrics.lines) { active = $0 } }
                }
            } else {
                Text(tr("Pas de paroles pour ce titre sur Deezer."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: player.current?.id) {
            loaded = false
            active = -1
            lyrics = nil
            if let id = player.current?.id { lyrics = await player.lyrics(id) }
            loaded = true
        }
    }
}

/// Prévient quand l'utilisateur déplace une liste à la main (`true`) et quand il la lâche (`false`). iOS 17 n'a pas de
/// suivi du défilement : un geste en parallèle, seulement au début du glissement.
struct ScrollWatch: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { old, new in
                if new == .interacting {
                    onChange(true)
                } else if old == .interacting {
                    onChange(false)
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in onChange(false) })
        }
    }
}

/// Repère la ligne en cours 4 fois par seconde (seulement en lecture, lecteur ouvert) ;
/// ne prévient que quand la ligne change.
private struct LyricsClock: View {
    @Environment(Player.self) private var player
    let lines: [LyricLine]
    let onLine: (Int) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !player.status.playing || !player.showFullPlayer)) { ctx in
            let ms = UInt64(max(0, player.position(at: ctx.date)) * 1000)
            let index = lines.lastIndex { $0.ms <= ms } ?? -1
            Color.clear.onChange(of: index, initial: true) { _, i in onLine(i) }
        }
    }
}

/// Crédits d'un titre (artistes, composition, paroles, production…), selon Deezer.
struct CreditsView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var credits: Credits?
    @State private var loaded = false
    @State private var tint: Color = Theme.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if !loaded {
                        ProgressView().padding(.top, 30)
                    } else if let credits, !credits.roles.isEmpty || credits.label != nil || credits.releaseDate != nil {
                        ForEach(credits.roles, id: \.role) { role in
                            CreditCard(title: role.role) {
                                ForEach(role.names, id: \.self) { name in
                                    Text(name).font(.body.weight(.medium))
                                }
                            }
                        }
                        if credits.label != nil || credits.releaseDate != nil {
                            CreditCard(title: tr("Sortie")) {
                                if let label = credits.label { LabeledContent("Label", value: label) }
                                if let date = credits.releaseDate { LabeledContent(tr("Date"), value: formatDay(date)) }
                            }
                        }
                    } else {
                        Label(tr("Deezer ne donne pas de crédits pour ce titre."), systemImage: "person.2.slash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .sheetBackground(tint, strength: 0.55)
            .navigationTitle(tr("Crédits"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("OK") { dismiss() }.fontWeight(.semibold) }
            .task {
                if let url = track.coverUrl, let c = await CoverLoader.shared.color(url: url) { tint = Color(uiColor: c) }
            }
            .task {
                credits = await player.credits(track.id)
                loaded = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 12) {
            CoverView(url: track.coverUrl, side: 150, radius: 14)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(track.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Carte d'un rôle : intitulé discret en couleur, puis les noms.
private struct CreditCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .surface(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false)
    }
}

/// Icône Aléatoire dessinée (deux flèches qui se croisent, comme celle d'iOS), pour pouvoir l'animer vraiment : à
/// chaque appui, les flèches se démêlent (leurs départs se rejoignent, elles s'écartent en fourche) puis se
/// recroisent avec un petit ressort, comme l'icône de « Répéter » qui se transforme. Dessin dans un carré de 24 x 24,
/// mis à l'échelle.
private struct ShuffleIcon: View {
    let on: Bool

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: on) { cross in
            Canvas { ctx, size in
                let s = size.width / 24
                // Trait de gauche à droite, en S, de la hauteur `from` à `to` ; il s'arrête dans la pointe.
                func line(_ from: CGFloat, _ to: CGFloat) -> Path {
                    var p = Path()
                    p.move(to: CGPoint(x: 3 * s, y: from * s))
                    p.addCurve(to: CGPoint(x: 17.5 * s, y: to * s),
                               control1: CGPoint(x: 10.5 * s, y: from * s), control2: CGPoint(x: 11.5 * s, y: to * s))
                    return p
                }
                // Pointe pleine aux coins arrondis, comme celles des icônes d'iOS.
                func head(_ y: CGFloat) -> Path {
                    var p = Path()
                    p.move(to: CGPoint(x: 21.2 * s, y: y * s))
                    p.addLine(to: CGPoint(x: 16.6 * s, y: (y - 3.6) * s))
                    p.addLine(to: CGPoint(x: 16.6 * s, y: (y + 3.6) * s))
                    p.closeSubpath()
                    return p
                }
                // `cross` : 1 = croisées (haut gauche → bas droite et inversement), 0 = départs réunis (fourche) ; les
                // pointes ne bougent pas.
                let under = line(12 - 5 * cross, 17)
                let over = line(12 + 5 * cross, 7)
                let stroke = StrokeStyle(lineWidth: 2 * s, lineCap: .round)
                let corners = StrokeStyle(lineWidth: 0.9 * s, lineJoin: .round)
                ctx.stroke(under, with: .foreground, style: stroke)
                ctx.fill(head(17), with: .foreground)
                ctx.stroke(head(17), with: .foreground, style: corners)
                // La seconde passe par-dessus : un trait plus large, vide, coupe la première au croisement. Il
                // s'efface vite quand elles se démêlent, pour ne pas entamer la fourche.
                ctx.blendMode = .destinationOut
                let gap = min(max((cross - 0.2) / 0.3, 0), 1)
                ctx.stroke(over, with: .color(.black.opacity(gap)), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))
                ctx.blendMode = .normal
                ctx.stroke(over, with: .foreground, style: stroke)
                ctx.fill(head(7), with: .foreground)
                ctx.stroke(head(7), with: .foreground, style: corners)
            }
            .frame(width: 22, height: 22)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0, duration: 0.16)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy(duration: 0.45, extraBounce: 0.15))
            }
        }
    }
}

/// Contour sombre très léger autour du texte et des icônes du lecteur : sur un fond clair (pochette blanche), le blanc
/// et la couleur d'accent restent lisibles ; sur un fond sombre, il ne se voit pas. La pochette n'est pas modifiée.
private extension View {
    func legible() -> some View {
        // Sans regroupement : chaque texte et chaque icône a son propre contour (le bouton AirPlay, une vue UIKit,
        // s'affiche ainsi normalement).
        shadow(color: .black.opacity(0.45), radius: 1.5)
            .shadow(color: .black.opacity(0.2), radius: 6)
    }
}
