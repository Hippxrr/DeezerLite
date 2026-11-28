import AVKit
import Observation
import SwiftUI

/// Glissement horizontal (mini-lecteur, grande pochette). Seul le modificateur qui applique le décalage le lit :
/// le contenu (pochettes, textes) n'est pas reconstruit à chaque mouvement du doigt.
@Observable
final class SlideState {
    var dx: CGFloat = 0
    @ObservationIgnored var axis: Axis?
    @ObservationIgnored private var speed = FingerSpeed()

    func track(_ x: CGFloat) { speed.track(x) }
    func fingerVelocity(fallback: CGFloat) -> CGFloat { speed.velocity(fallback: fallback) }

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

/// Deux dernières positions du doigt et leur moment : vitesse réelle au lâcher (carrousels, fermeture du lecteur).
struct FingerSpeed {
    private var samples: [(x: CGFloat, t: TimeInterval)] = []

    mutating func track(_ x: CGFloat) {
        samples.append((x, ProcessInfo.processInfo.systemUptime))
        if samples.count > 2 { samples.removeFirst() }
    }

    /// Vitesse du doigt sur ses deux derniers mouvements (points par seconde). Celle de `DragGesture` est lissée sur une
    /// période plus longue et sous-estime un lancer rapide : le ressort partait moins vite que le doigt, et la première
    /// image après le lâcher semblait freiner d'un coup. `fallback` si les mesures manquent ou sont trop anciennes.
    mutating func velocity(fallback: CGFloat) -> CGFloat {
        defer { samples = [] }
        guard samples.count == 2 else { return fallback }
        let (a, b) = (samples[0], samples[1])
        let dt = b.t - a.t
        let age = ProcessInfo.processInfo.systemUptime - b.t
        guard dt > 0.002, dt < 0.05, age < 0.05 else { return fallback }
        return (b.x - a.x) / dt
    }
}

/// Avance du ressort au lâcher (voir `HeadStartSpring`), réglée sur la vidéo : à 0, l'image du lâcher restait figée ;
/// à ~20 ms, la première image allait trop loin et la suivante presque pas (un autre accroc).
private let releaseHeadStart: TimeInterval = 0.01

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
    /// Titres d'avance pris par le carrousel, transmis au lecteur une fois le geste posé (voir `CarouselSteps`). Ici
    /// plutôt que dans le carrousel : le cœur suit le titre affiché au centre (voir `row`).
    @State private var steps = CarouselSteps()

    init(inBar: Bool = false, compact: Bool = false) {
        self.inBar = inBar
        self.compact = compact
    }

    private var row: some View {
        HStack(spacing: 8) {
            MiniCarousel(cover: inBar ? 34 : 44, steps: steps)
                // Place fixe : au-delà de ces tailles de texte, le titre et l'artiste étaient coupés.
                .dynamicTypeSize(...(inBar ? DynamicTypeSize.large : DynamicTypeSize.xLarge))
                .frame(height: inBar ? 40 : 46)
                .clipped()
            PlayButton(size: inBar ? 16 : 19)
            // Cœur du titre affiché au centre du carrousel. Avant, celui du lecteur : juste après un glissement, il restait
            // un instant celui du titre d'avant (vide, puis plein en même temps que la suite).
            if let t = steps.current(player), t.id != 0, !compact {
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
                    // Bulle flottante : verre en fond, le contenu dessiné par-dessus. Contenu dans le verre, celui-ci était
                    // recalculé à chaque image quand le titre glisse (iOS 26.0), comme dans l'ancienne barre de l'app.
                    .background { Color.clear.surface(bubble, interactive: false, material: true) }
                    .overlay { progress(bubble) },
                bubble
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            // Un peu moins large que la barre d'onglets ; ces marges ne réagissent pas au doigt (la liste dessous, si).
            .padding(.horizontal, 30)
        }
    }

}

/// Place sa vue à sa largeur naturelle plus la moitié de la place libre à sa droite (zone d'appui du titre et de l'artiste
/// élargie, avec une marge avant les boutons). Texte plus large que la place : toute la largeur.
private struct HalfGapLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let width = proposal.width ?? v.sizeThatFits(.unspecified).width
        return CGSize(width: width, height: v.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let natural = min(v.sizeThatFits(.unspecified).width, bounds.width)
        v.place(at: bounds.origin, proposal: ProposedViewSize(width: natural + (bounds.width - natural) / 2, height: bounds.height))
    }
}

/// Titre du mini-lecteur qu'on fait glisser. À part du mini-lecteur : pendant le glissement, seul ce carrousel est
/// redessiné (avant, tout le mini-lecteur pouvait l'être à chaque mouvement du doigt : boutons, barre de progression…).
private struct MiniCarousel: View {
    @Environment(Player.self) private var player
    let cover: CGFloat
    /// Titres d'avance pris par le carrousel (gardés par le mini-lecteur, voir `MiniPlayer.steps`).
    let steps: CarouselSteps
    @State private var slide = SlideState()
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
                guard horizontal else { steps.settle(slide: slide, player: player); return }
                let base = steps.base(player)
                let fling = v.predictedEndTranslation.width
                let forward = fling < -width * 0.35 && player.queue.indices.contains(base + 1)
                let backward = fling > width * 0.35 && player.queue.indices.contains(base - 1)
                steps.land(delta: forward ? 1 : backward ? -1 : 0, distance: width + MiniStrip.gap,
                           velocity: slide.fingerVelocity(fallback: v.velocity.width),
                           bounce: false, headStart: releaseHeadStart, waitFullStop: true,
                           coverPixels: Int(cover * UIScreen.main.scale), slide: slide, player: player)
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
    /// File en cours au premier pas de la série (voir `land`).
    @ObservationIgnored private var pendingQueue = 0

    /// Au lâcher : le carrousel glisse jusqu'au titre voisin (`delta` = ±1) ou revient en place (0), à la vitesse du doigt.
    /// Les titres affichés ne changent qu'une fois arrivé, d'un coup et sans animation (à cet instant, l'image est
    /// identique). Avant, ils changeaient au lâcher, pendant le ressort : la pochette du titre suivant prenait un autre
    /// trajet que son texte et passait dessous.
    /// `waitFullStop` : échange des titres une fois le ressort tout à fait arrêté (mini-lecteur : à « presque fini », la fin
    /// du trajet sautait de 2 à 3 points) ; sinon dès qu'il est presque arrivé, et le son suit aussitôt (grand lecteur, où
    /// l'attente avant le son se sentait).
    /// `coverPixels` : la pochette qui deviendra voisine après ce pas est préparée tout de suite. Pendant une série de
    /// glissements, le lecteur n'est pas prévenu et ne la préparait pas : elle arrivait vide, puis apparaissait.
    @MainActor func land(delta: Int, distance: CGFloat, velocity: CGFloat, bounce: Bool = true, headStart: TimeInterval = 0,
                         waitFullStop: Bool = false, coverPixels: Int, slide: SlideState, player: Player) {
        // Premier pas d'une série : la file à laquelle les pas s'appliquent (voir `schedule`).
        if pending == 0, landing == 0 { pendingQueue = player.queueGeneration }
        if delta != 0, let url = player.cover(neighbor(player, 2 * delta)) {
            CoverLoader.shared.prefetch([url], pixels: coverPixels)
        }
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
        // Gardé par la tâche (pas `weak`) : le grand lecteur, détruit à sa fermeture, emportait ce carrousel avec lui, et le
        // changement de titre déjà pris par un glissement était perdu.
        if delta != 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                guard id == self.landingID, self.landing != 0, slide.axis == nil else { return }
                self.landingID += 1
                self.commitLanding(slide: slide)
                self.schedule(slide: slide, player: player, after: .zero)
            }
        }
    }

    /// Nouveau glissement commencé pendant une arrivée : celle-ci est validée tout de suite.
    @MainActor func interrupt(slide: SlideState) {
        // Le changement de titre attendu ne tombe pas pendant ce nouveau glissement (il le figeait) : sa fin s'en chargera.
        flush?.cancel()
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
        let queue = pendingQueue
        // Gardé par la tâche (pas `weak`) : glisser vers le titre suivant puis fermer le grand lecteur aussitôt détruisait
        // ce carrousel avant l'envoi, et le titre ne changeait pas.
        flush = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.pending != 0, slide.axis == nil else { return }
            // Autre liste lancée entre-temps : les pas comptés concernaient l'ancienne (avant, ils faisaient sauter les
            // premiers titres de la nouvelle).
            guard player.queueGeneration == queue else { self.pending = 0; return }
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
    @Environment(Player.self) private var player
    let track: Track?
    let placeholder: String
    let side: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            if track != nil || !placeholder.isEmpty {
                if let track, track.id == 0 {
                    // Flow en cours de chargement (titre provisoire, voir `playFlow`) : un indicateur qui tourne.
                    ProgressView().frame(width: side, height: side)
                } else if let track {
                    // Identité liée à la pochette : jamais l'image du titre d'avant pendant une image.
                    CoverView(url: player.cover(track), side: side, radius: 8).id(player.cover(track) ?? "")
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
        let _ = player.playingSettled // redessin de rattrapage (voir `Player.status`)
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
            // Au moins 44 pt de large (mini-lecteur : 32) : un appui un peu à côté ouvrait le lecteur.
            .frame(width: max(size * 2, 44), height: size * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(player.status.playing ? tr("Pause") : tr("Lecture"))
    }
}

/// Cœur « J'aime » : animé, avec une petite vibration à l'ajout.
struct LikeButton: View {
    @Environment(Player.self) private var player
    /// Ligne d'une liste d'iOS (voir `TrackList`) : la confirmation est affichée par la page.
    @Environment(\.askUnlike) private var askUnlike
    let track: Track
    let size: CGFloat
    /// Ajouts faits par un appui : seul cela déclenche le rebond et la vibration (pas l'arrivée sur un titre aimé).
    @State private var likes = 0
    /// Retirer des titres aimés se confirme (ajouter, non). Titre gardé à l'appui : si le titre change pendant que la
    /// question est affichée, c'est bien celui-là qui est retiré (avant : le suivant).
    @State private var unlike: Track?

    var body: some View {
        let liked = player.lovedIds.contains(track.id)
        Button {
            if liked {
                if let askUnlike { askUnlike(track) } else { unlike = track }
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
        .accessibilityLabel(liked ? tr("Retirer des titres aimés") : tr("J'aime"))
        .accessibilityAddTraits(liked ? .isSelected : [])
        .sensoryFeedback(.success, trigger: likes)
        .confirmationDialog(tr("Retirer « %@ » de « %@ » ?", unlike?.title ?? track.title, player.lovedTitle),
                            isPresented: Binding(get: { unlike != nil }, set: { if !$0 { unlike = nil } }),
                            titleVisibility: .visible, presenting: unlike) { t in
            Button(tr("Retirer"), role: .destructive) { player.setLiked(t, false) }
        }
    }
}

// MARK: - Lecteur plein écran

/// Rayon des coins de l'écran : le grand lecteur a cette forme, et la garde en haut quand il descend.
enum DisplayCorners {
    /// shortcut: valeur interne d'iOS, lue seulement si elle existe (0 sinon : coins droits) ; à remplacer si Apple en publie une.
    @MainActor static let radius: CGFloat = {
        let key = "_displayCornerRadius"
        guard UIScreen.main.responds(to: NSSelectorFromString(key)) else { return 0 }
        return UIScreen.main.value(forKey: key) as? CGFloat ?? 0
    }()
}

/// Lecteur tiré vers le bas : c'est la vue présentée par iOS (le lecteur entier) qui est déplacée, par une simple
/// translation verticale, et ramenée ou envoyée en bas par un ressort d'UIKit. Le mouvement est fait par le système
/// d'affichage : rien n'est recalculé dans l'app pendant le geste ni pendant le ressort (avant, SwiftUI déplaçait le
/// lecteur à chaque image, et la moindre mise à jour en même temps faisait sauter une image).
@MainActor
final class PullState {
    /// Vue présentée par iOS (voir `PlayerSheet`).
    weak var view: UIView?
    /// Décalage vers le bas (0 = ouvert).
    private(set) var y: CGFloat = 0
    /// Position visée par le ressort en cours.
    private(set) var target: CGFloat = 0
    private var speed = FingerSpeed()
    /// Doigt sur le lecteur (glissement commencé, pas encore lâché).
    private var held = false

    private var height: CGFloat { view?.bounds.height ?? UIScreen.main.bounds.height }

    /// Coins de l'écran (rayon propre à chaque iPhone, 0 sur un écran à coins droits comme le SE) pendant que le lecteur
    /// bouge ; en place, coins droits : il couvre tout l'écran. Avec les coins arrondis en place, la courbe d'iOS ne
    /// tombait pas exactement sur celle de l'écran et un liseré de la page de derrière se voyait dans les angles.
    func round(_ on: Bool) {
        guard let layer = view?.layer else { return }
        layer.cornerRadius = on ? DisplayCorners.radius : 0
        layer.masksToBounds = on
    }

    /// Lecteur tiré par le doigt : vertical seulement, jamais au-dessus de sa place.
    func drag(to y: CGFloat) {
        if target != y { view?.layer.removeAllAnimations() } // ressort en cours rattrapé par le doigt
        held = true
        round(y > 0)
        self.y = y
        target = y
        speed.track(y)
        view?.transform = CGAffineTransform(translationX: 0, y: y)
    }

    /// Lâcher : le ressort part à la vitesse des derniers mouvements du doigt.
    func release(open: Bool, fallback: CGFloat, done: (() -> Void)? = nil) {
        settle(open: open, velocity: speed.velocity(fallback: fallback), done: done)
    }

    /// Geste annulé par le système alors que le lecteur était tiré vers le bas : il revient en place. Après un lâcher
    /// normal, le ressort est déjà parti : rien à faire. Avant, un lâcher pour fermer (tiré ailleurs que sur la pochette)
    /// était pris pour un geste annulé : le lecteur remontait, ou disparaissait d'un coup pendant qu'il remontait.
    func recover() {
        Task { @MainActor in
            await Task.yield()
            if held, y > 0 { settle(open: true) }
        }
    }

    /// Ressort qui part à la vitesse du doigt, sans rebond : remonte en place, ou descend jusqu'en bas (`done` ensuite).
    func settle(open: Bool, velocity: CGFloat = 0, done: (() -> Void)? = nil) {
        held = false
        guard let view else { done?(); return }
        target = open ? 0 : height
        let distance = target - y
        let relative = abs(distance) > 1 ? velocity / distance : 0
        y = target
        let end = target
        UIView.animate(withDuration: open ? 0.45 : 0.32, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: relative, options: [.allowUserInteraction, .beginFromCurrentState]) {
            view.transform = CGAffineTransform(translationX: 0, y: end)
        } completion: { [weak self] finished in
            guard finished else { return }
            if open { self?.round(false) }
            done?()
        }
    }
}

/// Grand lecteur présenté par iOS (voir `PlayerCover`) : il monte du bas de l'écran et y redescend, avec les coins de
/// l'écran pendant qu'il bouge ; en place, il couvre tout l'écran. Fermé, il n'existe plus : rien n'est gardé en mémoire
/// ni mis à jour à chaque titre.
struct PlayerSheet: View {
    @Environment(Player.self) private var player
    @State private var pull = PullState()
    /// Marges de l'écran (heure en haut, barre du bas), fixes. Celles d'iOS suivent la position du lecteur : tiré vers le
    /// bas, il n'est plus sous l'heure et sa marge du haut fondait. La pochette pleine largeur, posée sous l'heure, montait
    /// alors avec le doigt (et son fond était refait à chaque image du geste) ; au lâcher, la marge revenait d'un coup avant
    /// la remontée du lecteur, et la pochette retombait : le petit rebond.
    private let screen = PlayerSheet.screenInsets()

    var body: some View {
        NowPlayingView(pull: pull)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: screen.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: screen.bottom) }
            .ignoresSafeArea(.container, edges: .vertical)
            // Toujours en sombre, quel que soit le mode : son fond est la pochette assombrie (comme Apple Music).
            .environment(\.colorScheme, .dark)
            // Très grandes tailles de texte : bornées, sinon sur un petit iPhone (SE) le bas passait sous la barre.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .background(SheetHandle(pull: pull))
            // Fond transparent : l'app reste visible dessous quand on tire le lecteur vers le bas.
            .presentationBackground(.clear)
            // Fermé sans le geste (navigation, VoiceOver) : il redescend avec les coins de l'écran.
            .onChange(of: player.showFullPlayer) { _, open in if !open { pull.round(true) } }
    }
}

extension PlayerSheet {
    /// Marges de l'écran de l'app (heure, île, barre du bas).
    static func screenInsets() -> UIEdgeInsets {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window?.safeAreaInsets ?? .zero
    }
}

/// Retrouve la vue présentée par iOS (le lecteur entier) et la confie à `PullState`.
private struct SheetHandle: UIViewRepresentable {
    let pull: PullState

    func makeUIView(context: Context) -> SheetProbe {
        let probe = SheetProbe()
        probe.pull = pull
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ uiView: SheetProbe, context: Context) {}

    final class SheetProbe: UIView {
        weak var pull: PullState?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let pull, let presented = presentedController(), let sheet = presented.view else { return }
            sheet.layer.cornerCurve = .continuous
            pull.view = sheet
            // Coins arrondis pendant qu'il monte, droits une fois en place (voir `PullState.round`).
            pull.round(true)
            if let transition = presented.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak pull] _ in pull?.round(false) }
            } else {
                pull.round(false)
            }
        }

        /// Contrôleur présenté (et non un de ses enfants) : c'est sa vue qu'iOS fait monter et descendre.
        private func presentedController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController, let presenting = controller.presentingViewController {
                    return presenting.presentedViewController
                }
                responder = next
            }
            return nil
        }
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    /// Lecteur tiré vers le bas (voir `PullState`).
    let pull: PullState
    /// Grande pochette, ou à sa place la file d'attente ou les paroles (comme dans Apple Music).
    enum Panel { case cover, queue, lyrics }
    @State private var panel: Panel = .cover
    /// Titre à ajouter à une playlist, gardé à l'appui sur « + » (le titre peut changer pendant le choix).
    @State private var addToPlaylist: Track?
    /// Mode épuré (appui long sur la pochette) : seuls la pochette, le titre, l'artiste et la barre restent.
    @State private var clean = false
    /// Réglages › Apparence : pochette en haut de l'écran sur toute la largeur, fondue dans le fond.
    @AppStorage("fullBleedCover") private var fullBleed = false
    /// Réglages › Apparence : pochette pleine largeur haute jusqu'au titre (agrandie, coupée sur les côtés) ; sinon entière.
    @AppStorage("fullBleedTall") private var fullBleedTall = false
    /// Réglages : un appui long sur la pochette l'enregistre dans Photos, au lieu du mode épuré (désactivé par défaut).
    @AppStorage("saveCoverOnLongPress") private var saveCoverOnLongPress = false
    /// Haut du titre (sous la pochette), mesuré : la pochette pleine largeur descend jusque-là.
    @State private var titleTop: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, geo.size.height * 0.42)
            // Pochette pleine largeur : juste sous l'heure (au-dessus, le fond prolonge ses couleurs), sans marge sur les côtés,
            // ses bords haut et bas fondus dans le fond. Le titre et les boutons restent à leur place (celle de la pochette
            // normale reste vide). Paroles ou file ouvertes : elle s'efface, comme l'autre.
            let bleed = fullBleed && panel == .cover
            ZStack(alignment: .top) {
            if bleed {
                bleedCover(geo).transition(.opacity)
            }
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
                    if bleed {
                        Color.clear.frame(width: side, height: side)
                    } else {
                        CoverCarousel(side: side, width: geo.size.width, pull: pull, onPullEnd: pullEnded) { coverLongPress() }
                            .transition(.opacity)
                    }
                    Spacer(minLength: 8)
                    titleRow
                        .legible(grouped: true)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("player")).minY } action: { titleTop = $0 }
                        .padding(.bottom, 18)
                }
                VStack(spacing: 18) {
                    ScrubBar().id(player.current?.id)
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
            .animation(.easeInOut(duration: 0.3), value: clean)
            }
            .coordinateSpace(.named("player"))
            .animation(.easeInOut(duration: 0.3), value: panel)
            .background { bleedBackdrop(geo, shown: bleed) }
            .background { Backdrop(url: player.cover(player.current), open: player.showFullPlayer) }
        }
        // Retour haptique à l'appui long seulement (pas à la remise en mode normal quand le lecteur se ferme).
        .sensoryFeedback(trigger: clean) { _, _ in player.showFullPlayer ? .impact(weight: .medium) : nil }
        // Lecteur fermé : il se rouvre toujours en mode normal.
        .onChange(of: player.showFullPlayer) { _, open in if !open { clean = false } }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        // File ou paroles ouvertes : le geste est coupé pour laisser défiler la liste.
        .modifier(PullToClose(pull: pull, enabled: panel == .cover, onEnd: pullEnded))
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { player.showFullPlayer = false }
        // VoiceOver : fermeture proposée dans les actions (avant, seul le geste d'échappement à deux doigts la permettait).
        .accessibilityAction(named: Text(tr("Fermer le lecteur"))) { player.showFullPlayer = false }
    }

    /// Pochette pleine largeur, ses bords haut et bas fondus dans le fond. Sortie du `body` : tout dedans, il approchait de
    /// ce que le compilateur sait vérifier à temps.
    private func bleedCover(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            CoverCarousel(side: geo.size.width * (bleedFit(geo)?.zoom ?? 1), width: geo.size.width, pull: pull, bleed: true,
                          onPullEnd: pullEnded) { coverLongPress() }
                .mask { Self.bleedMask }
            Spacer(minLength: 0)
        }
        // Collée sous l'heure : la zone réservée en haut (île dynamique comprise) est plus haute que l'heure.
        .offset(y: -geo.safeAreaInsets.top * 0.3)
    }

    /// Bas fondu en courbe douce (pas de départ visible du fondu, comme une ligne). Haut fondu un peu plus long (7 %) : la
    /// jonction avec le fond se fait en douceur, les logos tout en haut restent lisibles. Sous ces fondus, le fond est flou
    /// (voir `CoverLoader.bleedBackdrop`) : la pochette se fond dans un flou d'elle-même, et pendant un changement de titre
    /// on n'y voit que des couleurs floues, jamais la pochette d'avant.
    private static let bleedMask = LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.7), .init(color: .black.opacity(0.74), location: 0.8),
                .init(color: .black.opacity(0.35), location: 0.88), .init(color: .black.opacity(0.07), location: 0.95),
                .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom)

    /// Pochette pleine largeur (réglage activé seulement) : son fond, aligné sous elle (mesures de l'écran), par-dessus le fond
    /// habituel. Paroles ou file ouvertes : il reste, encore plus flouté et assombri pour le texte. Avant, il s'effaçait et
    /// l'ancien fond flouté revenait, d'un autre style. Dans son propre `background`, pas avec le fond habituel : posés ensemble, il
    /// prenait la largeur de celui-ci (bien plus large que l'écran) et son image était étirée en largeur, d'où une copie de
    /// la pochette décalée qui se voyait sous son fondu (pattes d'un cheval en double).
    @ViewBuilder
    private func bleedBackdrop(_ geo: GeometryProxy, shown: Bool) -> some View {
        // Mesures pas encore connues (première mise en page) : rien. Hauteur bornée à 3 fois la largeur : une mesure à 0
        // donnait une image de centaines de milliers de pixels de haut (des centaines de Mo, l'app fermée par iOS).
        if fullBleed, let fit = bleedFit(geo) {
            Backdrop(url: player.cover(player.current), open: player.showFullPlayer, tall: fit.tall, inset: fit.inset, zoom: fit.zoom,
                     classic: !fullBleedTall, blurred: !shown)
                .animation(.easeInOut(duration: 0.3), value: shown)
        }
    }

    /// Mesures du fond pleine largeur (voir `Backdrop`) ; largeur ou titre pas encore mesurés : aucune. La pochette, posée
    /// sous l'heure, descend jusqu'au titre (comme Apple Music), son reflet commence là. Arrondie au point : une mesure qui
    /// varie d'une fraction ne refait pas le fond. Avant la mesure du titre (première image du lecteur, refait à chaque
    /// ouverture), le fond était fait une première fois avec une pochette carrée : un fond calculé pour rien à chaque
    /// ouverture, et celui déjà prêt (voir `Backdrop.init`) cherché avec ces mauvaises mesures, donc pas trouvé.
    private func bleedFit(_ geo: GeometryProxy) -> BleedFit? {
        guard geo.size.width >= 1, titleTop > 0 else { return nil }
        let screen = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        let height = (titleTop + geo.safeAreaInsets.top * 0.3).rounded()
        // Pochette haute : 4 % moins haute que la place jusqu'au titre (moins coupée sur les côtés, le reflet commence un peu
        // plus haut). Sinon entière : carrée, sur toute la largeur, son reflet flou descend jusqu'au titre.
        let zoom = fullBleedTall ? min(max(height * 0.96 / geo.size.width, 1), 1.8) : 1
        return BleedFit(tall: min(max(screen / geo.size.width, 1), 3), inset: geo.safeAreaInsets.top * 0.7 / geo.size.width,
                        zoom: zoom)
    }

    /// Lâcher du lecteur tiré vers le bas (voir `PullToClose`) : il se ferme ou revient en place.
    private func pullEnded(_ v: DragGesture.Value) {
        let close = v.translation.height > 140 || v.predictedEndTranslation.height > 260 || v.velocity.height > 800
        // Le ressort repart à la vitesse du doigt, dans un sens comme dans l'autre. À la fermeture, le reste de l'app
        // (mini-lecteur, pochettes, barres) n'est mis à jour qu'une fois le lecteur arrivé en bas : rien ne pèse
        // sur l'animation.
        if close {
            pull.release(open: false, fallback: v.velocity.height) {
                // Déjà en bas : retiré sans l'animation d'iOS (elle repartirait du haut).
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { player.showFullPlayer = false }
            }
        } else {
            pull.release(open: true, fallback: v.velocity.height)
        }
    }

    /// Appui long sur la pochette : mode épuré ; avec le réglage, pochette enregistrée dans Photos (et plus de mode épuré).
    private func coverLongPress() {
        if saveCoverOnLongPress {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            player.saveCurrentCoverToPhotos()
        } else {
            clean.toggle()
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let t = player.current, t.id != 0 {
                    // Appui sur le titre ou l'artiste : choisir lequel ouvrir (tous ceux d'un feat), l'album, les crédits ou le
                    // partage. Avant, seul l'artiste réagissait. La zone va jusqu'à la moitié de la place libre à droite du
                    // texte : une marge reste avant le « + » et le cœur.
                    HalfGapLayout {
                        // Menu ouvert par un bouton d'iOS invisible posé sur le titre (voir `TitleMenuButton`). Avant, un
                        // `Menu` SwiftUI : iOS 26 laissait un rectangle gris sur la zone d'appui une fois le menu refermé.
                        titleTexts(t)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay { TitleMenuButton(track: t, player: player) }
                    }
                } else if let t = player.current {
                    // Flow en chargement (« Chargement… ») : pas de menu, il n'y a ni artiste ni crédits à ouvrir.
                    titleTexts(t)
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

    /// Titre (réduit pour tenir sur la ligne plutôt que coupé par « … ») et artiste, sous la pochette.
    private func titleTexts(_ t: Track) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
            Text(t.artist).font(.title3).foregroundStyle(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    /// En-tête réduit quand la file d'attente ou les paroles sont ouvertes. Un appui sur la petite pochette ou sur le
    /// titre ferme le panneau et revient à la pochette en grand (le « + » et le cœur gardent leur propre action).
    private var compactHeader: some View {
        HStack(spacing: 14) {
            Button { panel = .cover } label: {
                HStack(spacing: 14) {
                    CoverView(url: player.cover(player.current), side: 64, radius: 8)
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
        if let t = player.current, t.id != 0 {
            Button { addToPlaylist = t } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: size + 4))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(tr("Ajouter à une playlist"))
            .popover(item: $addToPlaylist, arrowEdge: .bottom) { picked in
                PlaylistPicker(track: picked) { addToPlaylist = nil }
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
            .accessibilityLabel(tr("Titre précédent"))
            .skipEnabled(player.hasPrevious)
            Spacer()
            PlayButton(size: 40)
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 64, height: 64)
            }
            .accessibilityLabel(tr("Titre suivant"))
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
        .accessibilityLabel(target == .lyrics ? tr("Paroles") : tr("File d'attente"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Glissement vertical n'importe où sur le lecteur : tout le lecteur descend. Mesuré dans le repère de l'écran : le lecteur
/// qui bouge ne fausse pas la mesure. File ou paroles ouvertes (`enabled` faux) : coupé pour laisser défiler la liste.
/// À part du lecteur : poser ou lever le doigt ne redessine que ce petit morceau. Avant, l'état « doigt posé » était dans
/// le lecteur, refait en entier (titre, boutons, barre) au début et à la fin du geste : une image sautée au lâcher.
private struct PullToClose: ViewModifier {
    let pull: PullState
    let enabled: Bool
    let onEnd: (DragGesture.Value) -> Void
    /// Doigt posé sur le lecteur : revient à `false` même si le système annule le geste, sans `onEnded`.
    @GestureState private var pulling = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .updating($pulling) { _, state, _ in state = true }
                    .onChanged { v in
                        guard v.translation.height > abs(v.translation.width) || pull.y > 0 else { return }
                        pull.drag(to: max(0, v.translation.height))
                    }
                    .onEnded { v in
                        guard pull.y > 0 else { return }
                        onEnd(v)
                    },
                including: enabled ? .all : .subviews)
            .onChange(of: pulling) { _, on in if !on { pull.recover() } }
    }
}

extension Track {
    /// Artistes proposés par « Aller à l'artiste » : tous ceux d'un feat, sinon l'artiste principal.
    var artistLinks: [ArtistRef] {
        if !artists.isEmpty { return artists }
        return artistId != 0 ? [ArtistRef(id: artistId, name: artist)] : []
    }
}

/// Mesures du fond de la pochette pleine largeur, en largeurs d'écran (voir `Backdrop.tall` et `Backdrop.inset`).
private struct BleedFit {
    let tall: CGFloat
    let inset: CGFloat
    let zoom: CGFloat
}

/// Fond du lecteur : la pochette floutée en bonne qualité (voir `CoverLoader.backdrop`), assombrie pour le texte.
/// Rien n'est calculé en arrière-plan : le fond est fait (ou refait) au retour dans l'app.
private struct Backdrop: View {
    let url: String?
    /// Lecteur fermé : fond fait seulement à partir de la pochette déjà en mémoire, sans téléchargement.
    let open: Bool
    /// Pochette pleine largeur : hauteur de l'écran / largeur. Le fond suit la pochette posée en haut, puis prolonge
    /// les couleurs de son bas (voir `CoverLoader.bleedBackdrop`).
    var tall: CGFloat? = nil
    /// Hauteur de la barre d'état (heure, batterie) / largeur de l'écran : la pochette pleine largeur commence juste dessous.
    var inset: CGFloat = 0
    /// Pochette pleine largeur, paroles ou file ouvertes : fond flouté et assombri pour le texte (même image, rien à refaire).
    var blurred = false
    /// Hauteur de la pochette pleine largeur / largeur de l'écran (plus haute que large : coupée sur les côtés).
    var zoom: CGFloat = 1
    /// Pochette entière (« Pochette haute » désactivée) : le flou d'avant (voir `CoverLoader.bleedBackdrop`).
    var classic = false
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

    init(url: String?, open: Bool, tall: CGFloat? = nil, inset: CGFloat = 0, zoom: CGFloat = 1, classic: Bool = false,
         blurred: Bool = false) {
        self.url = url
        self.open = open
        self.tall = tall
        self.inset = inset
        self.zoom = zoom
        self.classic = classic
        self.blurred = blurred
        // Fond déjà prêt : affiché dès la première image (le lecteur présenté par iOS est construit à l'ouverture).
        _top = State(initialValue: url.flatMap { CoverLoader.shared.cachedBackdrop(url: $0, saturation: tall == nil ? 1.15 : 1, tall: tall, inset: inset, zoom: zoom,
                                                                                   classic: classic) })
    }

    var body: some View {
        ZStack {
            Color.black
            ZStack {
                if let below { layer(below) }
                if let top { layer(top).opacity(topOpacity) }
            }
            .opacity(shown)
            // Bords opaques : sans eux, le flou rendait les bords de l'écran transparents (fond noir dessous).
            .blur(radius: blurred ? 40 : 0, opaque: true)
            // Voile sombre : les couleurs restent présentes mais les écarts de clarté sont atténués. Pochette pleine largeur :
            // aucun voile jusqu'au bas de la pochette (elle n'en a pas : sur une pochette claire, la jonction faisait une bande
            // sombre), puis il s'assombrit peu à peu sous le titre et les boutons.
            if let tall {
                let end = min((inset + zoom) / tall, 0.8)
                LinearGradient(stops: [.init(color: .clear, location: end), .init(color: .black.opacity(0.3), location: min(end + 0.18, 0.95)),
                                       .init(color: .black.opacity(0.5), location: 1)], startPoint: .top, endPoint: .bottom)
                // Paroles ou file : le haut aussi est assombri, comme le fond habituel (texte lisible sur une pochette claire).
                Color.black.opacity(blurred ? 0.3 : 0)
            } else {
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        // Avec les mesures : un fond fait avec d'autres mesures (rotation, première mise en page) est refait.
        .task(id: "\(url ?? "")|\(phase == .background)|\(open)|\(tall ?? 0)|\(inset)|\(zoom)|\(classic)") {
            guard phase != .background else { return }
            // Titre sans pochette (image de secours) : fondu vers le noir.
            guard let url else { fadeToBlack(); return }
            func make() async -> UIImage? {
                if let tall {
                    return await CoverLoader.shared.bleedBackdrop(url: url, download: open, tall: tall, inset: inset, zoom: zoom, classic: classic)
                }
                return await CoverLoader.shared.backdrop(url: url, download: open, saturation: 1.15)
            }
            var image = await make()
            // Titre changé pendant la préparation : le fond de l'ancien ne s'affiche pas sous le nouveau.
            guard !Task.isCancelled else { return }
            // Lecteur ouvert, échec (réseau faible) : fondu vers le noir (pas le fond du titre d'avant), puis nouvel essai
            // après 2, 5 puis 15 s. Avant, le fond restait noir jusqu'au titre suivant ou au relancement de l'app.
            if image == nil, open {
                fadeToBlack()
                for delay in [2, 5, 15] where image == nil {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    image = await make()
                }
                guard !Task.isCancelled else { return }
            }
            guard let img = image else {
                // Lecteur fermé et pochette pas encore en mémoire : le fond sera fait à l'ouverture. Pleine largeur : celui de
                // l'ancien titre est oublié (il se voyait sous la nouvelle pochette en rouvrant le lecteur) ; le fond flouté
                // habituel, dessous, s'affiche le temps que le nouveau soit prêt.
                if open {
                    fadeToBlack()
                } else if tall != nil {
                    below = nil
                    top = nil
                    shown = 0
                }
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

    @ViewBuilder
    private func layer(_ image: UIImage) -> some View {
        if tall != nil {
            // Aux proportions de l'écran : rien n'est recadré, l'image tombe exactement sous la pochette nette. Mêmes couleurs
            // qu'elle (sans saturation en plus) : aucune jonction visible.
            Image(uiImage: image).resizable().interpolation(.high)
        } else {
            // Remplissage sans agrandir la vue : l'image carrée, à la hauteur de l'écran, est bien plus large que lui ; posée
            // telle quelle, elle donnait cette largeur au fond entier (et à ce qui est posé avec lui).
            // Saturation déjà appliquée au fond (voir `CoverLoader.backdrop`), pas à chaque image.
            Color.clear.overlay { Image(uiImage: image).resizable().interpolation(.high).scaledToFill() }
        }
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
    /// Pochette pleine largeur : sans coins arrondis ni ombre, et pas réduite en pause. `side` est alors sa hauteur (jusqu'au
    /// titre, comme Apple Music) : plus haute que large, elle est coupée aux bords de l'écran.
    var bleed = false
    let onPullEnd: (DragGesture.Value) -> Void
    /// Appui long : mode épuré du lecteur.
    let onLongPress: () -> Void
    @State private var slide = SlideState()
    /// Doigt posé : revient à `false` même si le système annule le geste, sans `onEnded`.
    @GestureState private var dragging = false
    @State private var steps = CarouselSteps()

    /// Pleine largeur : pochettes bord à bord, comme Apple Music.
    private var step: CGFloat { bleed ? width : (width + side) / 2 + 12 }
    private var radius: CGFloat { bleed ? 0 : 14 }

    /// Pochette précédente (-1), en cours (0) ou suivante (1).
    private struct Slot: Identifiable {
        let id: String
        let offset: Int
        let track: Track?
    }

    var body: some View {
        let base = steps.base(player)
        let active = player.status.playing || player.loading
        let open = player.showFullPlayer
        let slots = [(-1, steps.neighbor(player, -1)), (0, steps.current(player)), (1, steps.neighbor(player, 1))]
            .filter { $0.0 == 0 || $0.1 != nil }
            // Identité : la place dans la file et l'image. Au passage au titre voisin, la pochette qui arrive au centre reste
            // la même vue (seule celle qui entre, hors champ, est construite). Avant, les trois pochettes étaient refaites à
            // ce moment-là, en plein glissement : une image sautée à chaque titre quand on en passe plusieurs d'affilée.
            .map { Slot(id: "\(base + $0.0)|\(player.cover($0.1) ?? "")", offset: $0.0, track: $0.1) }
        ZStack {
            ForEach(slots) { slot in
                let center = slot.offset == 0
                Group {
                    if slot.track?.id == 0 {
                        // Flow en chargement : indicateur, pas la pochette de secours des MP3 importés.
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white.opacity(0.08))
                            .frame(width: bleed ? width : side, height: side)
                            .overlay { ProgressView().controlSize(.large).tint(.white) }
                    } else {
                        // Lecteur fermé : pas de téléchargement de la grande pochette à chaque titre.
                        page(CoverView(url: player.cover(slot.track), side: side, radius: radius, load: open, large: bleed))
                    }
                }
                // Ombre et taille réglées par des valeurs (pas des modificateurs ajoutés ou retirés) : devenir la pochette du
                // centre ne change pas la structure de la vue, rien n'est reconstruit.
                .shadow(color: .black.opacity(bleed || !center ? 0 : 0.4), radius: center && active ? 24 : 12, y: center && active ? 14 : 6)
                // Pochette réduite en pause, pleine taille en lecture (comme Apple Music). Pleine largeur : aucun effet.
                .scaleEffect(!center || active || bleed ? 1 : 0.8)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: active)
                .offset(x: CGFloat(slot.offset) * step)
                .zIndex(center ? 1 : 0) // ombre du centre par-dessus les voisines, comme avant
            }
        }
        .modifier(SlideOffset(state: slide))
        .frame(width: bleed ? width : side, height: side)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Annulé dès que le doigt glisse : le défilement des pochettes et le geste de fermeture restent prioritaires.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress() })
        .gesture(drag)
        .onChange(of: dragging) { _, on in
            if !on { slide.recover { pull.recover(); steps.settle(slide: slide, player: player) } }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { v in
                if slide.axis == nil {
                    steps.interrupt(slide: slide)
                    slide.axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                if slide.axis == .vertical {
                    pull.drag(to: max(0, v.translation.height))
                } else {
                    follow(v.translation.width)
                }
            }
            .onEnded { v in
                let vertical = slide.axis == .vertical
                slide.axis = nil
                // Titres d'avance pris avant ce geste vertical : le lecteur en est prévenu quand même.
                if vertical { onPullEnd(v); steps.settle(slide: slide, player: player); return }
                release(fling: v.predictedEndTranslation.width, velocity: v.velocity.width)
            }
    }

    /// Pleine largeur : pochette agrandie (plus haute que l'écran n'est large), coupée aux bords de l'écran.
    @ViewBuilder
    private func page(_ cover: CoverView) -> some View {
        if bleed {
            cover.frame(width: width, height: side).clipped()
        } else {
            cover
        }
    }

    /// Pochettes qui suivent le doigt. Pas de voisine de ce côté : résistance élastique.
    private func follow(_ width: CGFloat) {
        let blocked = (width > 0 && steps.neighbor(player, -1) == nil) || (width < 0 && steps.neighbor(player, 1) == nil)
        slide.dx = blocked ? width * 0.3 : width
        slide.track(slide.dx)
    }

    /// Lâcher : pochette voisine si l'élan suffit, sinon retour en place.
    private func release(fling: CGFloat, velocity: CGFloat) {
        let forward = fling < -min(side, width) * 0.35 && steps.neighbor(player, 1) != nil
        let backward = fling > min(side, width) * 0.35 && steps.neighbor(player, -1) != nil
        // Changement de titre une fois la pochette tout à fait arrêtée, comme le mini-lecteur : fait pendant la
        // fin de sa course, il la figeait un instant (titre, barre, fond refaits d'un coup), puis elle sautait.
        steps.land(delta: forward ? 1 : backward ? -1 : 0, distance: step,
                   velocity: slide.fingerVelocity(fallback: velocity), headStart: releaseHeadStart,
                   waitFullStop: true, coverPixels: bleed ? CoverLoader.large : Int(side * UIScreen.main.scale),
                   slide: slide, player: player)
    }

}

/// Barre de progression : fine au repos, plus épaisse sous le doigt ; le saut n'est envoyé qu'au lâcher.
/// Elle glisse en continu (voir `ProgressLine`) au lieu d'avancer seconde par seconde ; lecteur fermé, elle ne tourne
/// pas (elle repart à l'ouverture, directement à la bonne position, sans être refaite : moins de travail au moment où le
/// lecteur commence à monter).
struct ScrubBar: View {
    @Environment(Player.self) private var player
    /// Position tenue sous le doigt. `@GestureState` : remise à zéro aussi quand iOS interrompt le geste (appel), sinon
    /// la barre restait épaisse et figée jusqu'au titre suivant.
    @GestureState private var dragging: Double?

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
                            // Sans animation (comme la barre du mini-lecteur) : elle avance de moins d'un point par relevé, et
                            // l'animation la faisait redessiner à chaque image de l'écran tant que le lecteur était ouvert.
                    }
                    .frame(height: dragging == nil ? 6 : 11)
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragging) { v, state, _ in state = min(max(v.location.x / geo.size.width, 0), 1) * total }
                            .onEnded { v in player.seek(seconds: min(max(v.location.x / geo.size.width, 0), 1) * total) }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging == nil)
                }
                .frame(height: 24)
                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-" + formatTime(total - shown))
                        .opacity(player.status.durationMs == 0 ? 0 : 1) // durée pas encore connue : pas de « -0:01 »
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(dragging == nil ? 0.55 : 0.9))
            }
            // Ici, recalculé avec l'affichage : avant, VoiceOver lisait la position du dernier événement (« 0:00 »).
            .accessibilityElement()
            .accessibilityLabel(tr("Position"))
            .accessibilityValue(tr("%@ sur %@", formatTime(shown), formatTime(total)))
            .accessibilityAdjustableAction { dir in
                let target = player.position(at: .now) + (dir == .increment ? 15 : -15)
                player.seek(seconds: min(max(target, 0), max(total - 1, 0)))
            }
        }
        .sensoryFeedback(.selection, trigger: dragging == nil)
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
                .overlay(alignment: .topTrailing) {
                    if player.sleepTimer != nil {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .offset(x: -5, y: 7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: player.sleepTimer)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tr("Son"))
        .accessibilityValue(player.sleepTimer != nil ? tr("Minuterie active") : "")
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
                        .accessibilityLabel(tr("Préréglage précédent"))
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        Image(systemName: player.eqPreset.icon).foregroundStyle(Theme.accent)
                        Text(player.eqPreset.name).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    Button { player.stepEqPreset(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                        .accessibilityLabel(tr("Préréglage suivant"))
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.15), value: player.eqPreset)
                .transition(.opacity)
            }
            Divider()
            // Minuterie de sommeil : seulement ici, et un petit croissant sur le bouton « Son » quand elle est réglée.
            Menu {
                Picker(tr("Minuterie"), selection: Binding(get: { player.sleepTimer }, set: { player.setSleepTimer($0) })) {
                    Text(tr("Désactivée")).tag(Player.SleepTimer?.none)
                    ForEach([15, 30, 45, 60], id: \.self) { m in
                        Text(tr("%@ min", "\(m)")).tag(Player.SleepTimer?.some(.minutes(m)))
                    }
                    Text(tr("Fin du titre")).tag(Player.SleepTimer?.some(.trackEnd))
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz").foregroundStyle(Theme.accent).frame(width: 24)
                    Text(tr("Minuterie")).foregroundStyle(Color.primary)
                    Spacer()
                    sleepValue.font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
        }
        .frame(width: 280)
        .sensoryFeedback(.selection, trigger: player.eqPreset)
        .sensoryFeedback(.selection, trigger: player.sleepTimer)
    }

    /// Décompte affiché par le système (aucune minuterie de l'app pour le faire avancer).
    @ViewBuilder private var sleepValue: some View {
        switch player.sleepTimer {
        case nil:
            Text(tr("Désactivée"))
        case .trackEnd?:
            Text(tr("Fin du titre"))
        case .minutes?:
            if let at = player.sleepAt {
                let now = Date()
                Text(timerInterval: now...max(at, now), countsDown: true).monospacedDigit()
            }
        }
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
                    if player.library[0] == nil, player.loadFailed.contains("library0") {
                        Button(tr("Réessayer")) { Task { await player.loadLibrary(0, force: true) } }
                            .frame(maxWidth: .infinity).padding(20)
                    } else if player.library[0] == nil {
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

/// Une ligne de la file. Identité : le titre et sa nième apparition (un même titre peut y être deux fois). Repérée par sa
/// position, une ligne retirée animait la dernière, et un menu ouvert passait sur le titre voisin.
private struct QueueRow: Hashable {
    let id: String
    let index: Int
}

/// File d'attente dans le lecteur, comme Apple Music : titres déjà écoutés au-dessus (cachés à l'ouverture, visibles en
/// remontant), puis « À suivre ». Appui = lire (un titre déjà écouté est relancé et ceux d'après redeviennent « À suivre ») ;
/// appui long = déplacer, vers le haut ou le bas seulement ; glissement à gauche = retirer.
private struct QueuePanel: View {
    @Environment(Player.self) private var player
    /// Réglages › Apparence : titres déjà écoutés au-dessus d'« À suivre » (activé par défaut).
    @AppStorage("queueHistory") private var showHistory = true

    /// Lignes déjà calculées, gardées tant que la file ne change pas. Avant, des milliers de textes et un dictionnaire
    /// étaient refaits à chaque mise à jour du lecteur, panneau ouvert. Objet (pas une valeur) : le remplir pendant
    /// l'affichage ne relance pas l'affichage.
    private final class RowCache {
        var ids: [Int64] = []
        var rows: [QueueRow] = []
    }
    @State private var cache = RowCache()

    private var rows: [QueueRow] {
        let ids = player.queue.map(\.id)
        if cache.ids == ids, !cache.rows.isEmpty || ids.isEmpty { return cache.rows }
        var seen: [Int64: Int] = [:]
        let rows = ids.indices.map { i in
            let track = ids[i]
            let nth = seen[track, default: 0]
            seen[track] = nth + 1
            return QueueRow(id: "\(track)-\(nth)", index: i)
        }
        cache.ids = ids
        cache.rows = rows
        return rows
    }

    var body: some View {
        // Pochettes réparées suivies ici : leurs lignes sont alors refaites (la liste d'iOS ne les suit pas elle-même).
        QueueList(player: player, rows: rows, current: player.queueIndex, fixes: player.coverFixes.count, history: showHistory)
    }
}

/// Liste d'iOS qui prévient à chaque mise en page (taille connue, lignes mesurées) : file d'attente et paroles.
private final class WatchedCollectionView: UICollectionView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Liste d'UIKit : son déplacement à l'appui long garde la ligne elle-même, tenue à la verticale (celui de la liste de
/// SwiftUI soulevait un aperçu sombre qu'on promenait partout), et le glissement à gauche pour retirer est celui d'iOS.
private struct QueueList: UIViewRepresentable {
    let player: Player
    let rows: [QueueRow]
    let current: Int
    /// Nombre de pochettes réparées : en changeant, il fait refaire les lignes (voir `Coordinator.update`).
    let fixes: Int
    /// Réglages › Apparence : titres déjà écoutés affichés au-dessus d'« À suivre ».
    let history: Bool

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeView() }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.showsHistory = history
        context.coordinator.update(rows: rows, current: current)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        enum Section: Hashable { case history, next }
        private static let empty = "empty"
        /// Historique affiché (réglage) : sinon la file commence à « À suivre ».
        var showsHistory = true

        private let player: Player
        private weak var view: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
        /// Ligne → place dans la file.
        private var indexOf: [String: Int] = [:]
        private var current = 0
        private var nextCount = 0
        /// Première mise en place faite (« À suivre » amené en haut une seule fois).
        private var placed = false
        /// Déplacement en cours : la file n'est pas réappliquée pendant ce temps.
        private var moving = false
        private var pending: (rows: [QueueRow], current: Int)?

        init(player: Player) { self.player = player }

        func makeView() -> UICollectionView {
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            config.headerMode = .supplementary
            config.headerTopPadding = 0
            config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.removeAction(at: path) }
            let layout = UICollectionViewCompositionalLayout { _, environment in
                let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                section.boundarySupplementaryItems.forEach { $0.pinToVisibleBounds = false }
                return section
            }
            let view = WatchedCollectionView(frame: .zero, collectionViewLayout: layout)
            view.onLayout = { [weak self] in self?.laidOut() }
            view.backgroundColor = .clear
            view.overrideUserInterfaceStyle = .dark
            view.delegate = self
            self.view = view

            let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
                guard let self else { return }
                cell.backgroundConfiguration = .clear()
                guard let i = self.indexOf[id], self.player.queue.indices.contains(i) else {
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(tr("Rien d'autre dans la file.")).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.margins(.horizontal, 0)
                    return
                }
                let t = self.player.queue[i]
                let cover = self.player.mp3Cover(t) ?? self.player.coverFixes[t.id] ?? t.coverUrl
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack(spacing: 12) {
                        CoverView(url: cover, side: 44, radius: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                            Text(t.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .margins(.horizontal, 0)
                .margins(.vertical, 5)
                cell.accessibilityTraits = .button
            }
            let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, path in
                self?.configure(header: cell, at: path)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, path, id in
                view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
            }
            dataSource.supplementaryViewProvider = { view, _, path in
                view.dequeueConfiguredReusableSupplementary(using: header, for: path)
            }
            dataSource.reorderingHandlers.canReorderItem = { [weak self] id in
                self?.dataSource.snapshot().sectionIdentifier(containingItem: id) == .next && id != Self.empty
            }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in self?.reordered(transaction) }

            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.3
            view.addGestureRecognizer(press)
            return view
        }

        private func configure(header cell: UICollectionViewListCell, at path: IndexPath) {
            let section = dataSource.sectionIdentifier(for: path.section)
            let count = section == .next ? nextCount : 0
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = UIHostingConfiguration {
                HStack(spacing: 8) {
                    Text(section == .history ? tr("Historique") : tr("À suivre")).font(.headline).foregroundStyle(.white)
                    if count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.white.opacity(0.55)) }
                    Spacer(minLength: 0)
                }
            }
            .margins(.horizontal, 0)
            .margins(.vertical, 8)
        }

        func update(rows: [QueueRow], current: Int) {
            if moving { pending = (rows, current); return }
            guard let view else { return }
            // Titre suivant : la liste garde sa place par rapport à « À suivre » (l'historique reste caché).
            let shift = current != self.current && placed && !view.isDragging
                ? nextHeader().map { view.contentOffset.y + view.adjustedContentInset.top - $0.minY } : nil
            self.current = current
            indexOf = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.index) })
            let history = showsHistory ? rows.prefix(min(current, rows.count)).map(\.id) : []
            let next = rows.dropFirst(min(current + 1, rows.count)).map(\.id)
            let countChanged = next.count != nextCount
            nextCount = next.count
            var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            if !history.isEmpty {
                snapshot.appendSections([.history])
                snapshot.appendItems(history, toSection: .history)
            }
            snapshot.appendSections([.next])
            snapshot.appendItems(next.isEmpty ? [Self.empty] : next, toSection: .next)
            // Titre réparé ou pochette retrouvée : lignes déjà là redessinées.
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.indexPath(for: $0) != nil })
            dataSource.apply(snapshot, animatingDifferences: placed) { [weak self] in
                guard let self else { return }
                if countChanged { self.refreshNextHeader() }
                // Historique déjà ouvert à la main (shift négatif) : laissé tel quel.
                guard let shift, shift >= -1 else { return }
                view.layoutIfNeeded()
                self.fitBottom()
                if let header = self.nextHeader() {
                    view.setContentOffset(CGPoint(x: 0, y: header.minY - view.adjustedContentInset.top + max(0, shift)), animated: true)
                }
            }
        }

        /// À chaque mise en page : place sous la fin de la file, et à la première (taille connue) « À suivre » amené en haut.
        private func laidOut() {
            guard let view, view.bounds.height > 0, dataSource.snapshot().numberOfItems > 0 else { return }
            fitBottom()
            guard !placed else { return }
            placed = true
            showNext()
            // Lignes mesurées pendant ce premier défilement : position reprise une fois leur taille connue.
            DispatchQueue.main.async { [weak self] in self?.showNext() }
        }

        private func refreshNextHeader() {
            guard let view, let section = dataSource.snapshot().indexOfSection(.next) else { return }
            let path = IndexPath(item: 0, section: section)
            if let header = view.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path) as? UICollectionViewListCell {
                configure(header: header, at: path)
            }
        }

        /// Place sous la fin de la file : « À suivre » peut monter tout en haut, l'historique reste caché au-dessus.
        private func fitBottom() {
            guard let view, let header = nextHeader() else { return }
            let below = view.collectionViewLayout.collectionViewContentSize.height - header.minY
            let inset = max(0, view.bounds.height - below)
            if abs(view.contentInset.bottom - inset) > 1 { view.contentInset.bottom = inset }
        }

        /// À l'ouverture : « À suivre » en haut, l'historique caché au-dessus (visible en remontant).
        private func showNext() {
            guard let view, let section = dataSource.snapshot().indexOfSection(.next) else { return }
            view.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
            view.layoutIfNeeded()
            if let header = nextHeader() { view.contentOffset.y = header.minY - view.adjustedContentInset.top }
        }

        private func nextHeader() -> CGRect? {
            guard let view, let section = dataSource.snapshot().indexOfSection(.next) else { return nil }
            return view.collectionViewLayout.layoutAttributesForSupplementaryView(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))?.frame
        }

        // MARK: Gestes

        /// Appui long : la ligne suit le doigt, à la verticale seulement (le doigt peut aller sur le côté, pas la ligne).
        @objc private func pressed(_ press: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = press.location(in: view)
            let held = CGPoint(x: view.bounds.midX, y: point.y)
            switch press.state {
            case .began:
                guard let path = view.indexPathForItem(at: point),
                      let id = dataSource.itemIdentifier(for: path),
                      dataSource.snapshot().sectionIdentifier(containingItem: id) == .next, id != Self.empty,
                      view.beginInteractiveMovementForItem(at: path) else { return }
                moving = true
                lift(view.cellForItem(at: path) as? UICollectionViewListCell)
                UISelectionFeedbackGenerator().selectionChanged()
                view.updateInteractiveMovementTargetPosition(held)
            case .changed:
                view.updateInteractiveMovementTargetPosition(held)
            case .ended:
                view.endInteractiveMovement()
                finishMove()
            default:
                view.cancelInteractiveMovement()
                finishMove()
            }
        }

        /// Ligne déplacée : fond givré clair (pas noir) sous elle, pour ne pas se mêler aux textes qu'elle survole.
        private weak var lifted: UICollectionViewListCell?

        private func lift(_ cell: UICollectionViewListCell?) {
            var background = UIBackgroundConfiguration.clear()
            background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            background.backgroundColor = .white.withAlphaComponent(0.14)
            background.cornerRadius = 10
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: -8, bottom: 0, trailing: -8)
            cell?.backgroundConfiguration = background
            lifted = cell
        }

        private func finishMove() {
            guard moving else { return }
            moving = false
            lifted?.backgroundConfiguration = .clear()
            lifted = nil
            if let pending { self.pending = nil; update(rows: pending.rows, current: pending.current) }
        }

        /// Ligne posée : le titre est déplacé dans la file (du lecteur), à sa nouvelle place parmi « À suivre ».
        private func reordered(_ transaction: NSDiffableDataSourceTransaction<Section, String>) {
            guard let change = transaction.sectionTransactions.first(where: { $0.sectionIdentifier == .next }) else { return }
            for step in change.difference.inferringMoves() {
                if case let .insert(to, _, from?) = step {
                    player.queueMove(from: current + 1 + from, to: current + 1 + to)
                    return
                }
            }
        }

        /// Déplacement gardé dans « À suivre » (jamais dans les titres déjà écoutés).
        func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath original: IndexPath,
                            atCurrentIndexPath current: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
            dataSource.sectionIdentifier(for: proposed.section) == .next ? proposed : current
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt path: IndexPath) -> Bool {
            dataSource.itemIdentifier(for: path).map { indexOf[$0] != nil } ?? false
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
            collectionView.deselectItem(at: path, animated: false)
            guard let id = dataSource.itemIdentifier(for: path), let i = indexOf[id] else { return }
            player.queuePlay(i)
        }

        private func removeAction(at path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let id = dataSource.itemIdentifier(for: path), let i = indexOf[id],
                  dataSource.snapshot().sectionIdentifier(containingItem: id) == .next else { return nil }
            let remove = UIContextualAction(style: .destructive, title: tr("Retirer")) { [weak self] _, _, done in
                self?.player.queueRemove(i)
                done(true)
            }
            remove.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [remove])
        }
    }
}

/// Paroles Deezer dans le lecteur : la ligne en cours est mise en avant et reste au centre ;
/// un appui sur une ligne y amène la lecture. Paroles non synchronisées : simple texte.
private struct LyricsPanel: View {
    @Environment(Player.self) private var player
    @State private var lyrics: Lyrics?
    @State private var loaded = false
    /// Paroles pas chargées (réseau) ; `attempt` relance le chargement (bouton « Réessayer »).
    @State private var failed = false
    @State private var attempt = 0
    /// Demande déjà faite (titre et essai) : au retour dans l'app, rien n'est redemandé si le titre n'a pas changé.
    @State private var shownFor: String?
    @Environment(\.scenePhase) private var phase
    /// Ligne en cours (-1 : avant la première).
    @State private var active = -1
    /// Ligne touchée et moment de l'appui : elle reste la ligne en cours jusqu'à ce que la lecture y soit (2 s au plus).
    /// Avant, la position du lecteur, juste après le saut, était encore un peu avant la ligne (ou l'ancienne position) : la
    /// ligne d'au-dessus s'allumait une demi-seconde, et le texte allait vers elle avant de revenir.
    @State private var tapped: (line: Int, at: Date)?
    /// Lignes à partager en image (appui long sur une ligne).
    @State private var share: LyricsShareRequest?

    var body: some View {
        Group {
            if !loaded {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics {
                LyricsList(lyrics: lyrics, active: active, onTap: { i in
                    // Paroles synchronisées : un appui amène la lecture à cette ligne.
                    player.seek(seconds: Double(lyrics.lines[i].ms) / 1000)
                    tapped = (i, Date())
                    active = i
                }, onShare: { i in shareLine(i, lyrics) })
                // Paroles rechargées (autre titre, nouvel essai) : liste refaite, à la bonne ligne.
                .id(shownFor)
                .background {
                    if lyrics.synced {
                        LyricsClock(lines: lyrics.lines) { i in
                            // Seule une ligne d'avant la ligne touchée est ignorée (le saut pas encore fait) : la ligne
                            // suivante s'allume normalement, même si on a touché la ligne en cours.
                            if let t = tapped, i < t.line, Date().timeIntervalSince(t.at) < 2 { return }
                            tapped = nil
                            active = i
                        }
                    }
                }
            } else if failed {
                VStack(spacing: 12) {
                    Text(tr("Impossible de charger les paroles. Vérifie ta connexion."))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button(tr("Réessayer")) { attempt += 1 }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(tr(player.geniusLyrics ? "Pas de paroles chez Deezer ni sur Genius." : "Pas de paroles pour ce titre sur Deezer."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $share) { request in
            LyricsShareSheet(request: request).environment(player)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: share?.id)
        .task(id: "\(player.current?.id ?? 0)-\(player.showFullPlayer)-\(attempt)-\(phase == .background)") {
            let key = "\(player.current?.id ?? 0)-\(attempt)"
            // Lecteur fermé : les paroles restent (rouvert sur le même titre, elles sont là, à leur place ; avant, « Pas de
            // paroles » s'affichait puis tout se rechargeait). Autre titre entre-temps : effacées, rechargées à l'ouverture.
            guard player.showFullPlayer else {
                if shownFor != nil, key != shownFor {
                    shownFor = nil
                    lyrics = nil
                    loaded = false
                    failed = false
                    active = -1
                    tapped = nil
                }
                return
            }
            // App en arrière-plan : rien n'est demandé (personne ne les lit). Au retour, seulement si le titre a changé.
            guard phase != .background, key != shownFor else { return }
            shownFor = key
            loaded = false
            failed = false
            active = -1
            tapped = nil
            lyrics = nil
            if let track = player.current, track.id != 0 {
                // Interrompu (arrière-plan, autre titre) : rien n'est affiché (les paroles de l'ancien titre remplaçaient
                // celles du nouveau), refait au prochain affichage.
                do {
                    let found = try await player.lyrics(track)
                    if Task.isCancelled { shownFor = nil; return }
                    lyrics = found
                } catch {
                    if Task.isCancelled { shownFor = nil; return }
                    failed = true
                }
            }
            loaded = true
        }
    }

    private func shareLine(_ i: Int, _ lyrics: Lyrics) {
        guard let track = player.current, track.id != 0,
              !lyrics.lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        share = LyricsShareRequest(track: track, lines: lyrics.lines, first: i)
    }
}

/// Lignes des paroles dans une liste d'iOS (comme la file d'attente) : seules les lignes à l'écran existent, et la ligne en
/// cours est amenée au centre par le défilement d'iOS. Avant, une liste SwiftUI : toutes les lignes mises en page à chaque
/// changement de ligne, et un défilement moins doux. Ligne en cours en blanc, les autres atténuées (paroles synchronisées) ;
/// appui = aller à cette ligne ; appui long = partager en image. Défilé à la main : le suivi reprend 4 s après le lâcher.
private struct LyricsList: UIViewRepresentable {
    let lyrics: Lyrics
    let active: Int
    let onTap: (Int) -> Void
    let onShare: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeView(lyrics) }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onShare = onShare
        context.coordinator.show(active)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        enum Item: Hashable { case genius, line(Int), copyright }

        var onTap: (Int) -> Void = { _ in }
        var onShare: (Int) -> Void = { _ in }
        private var synced = false
        private weak var view: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
        /// Ligne en cours (-1 : avant la première).
        private var active = -1
        /// Ligne à centrer dès que la liste a sa taille (ouverture des paroles).
        private var pendingCenter: Int?
        /// Jusqu'à quand le texte ne suit plus la ligne en cours (l'utilisateur le fait défiler).
        private var readingUntil = Date.distantPast

        func makeView(_ lyrics: Lyrics) -> UICollectionView {
            synced = lyrics.synced
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let view = WatchedCollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
            view.onLayout = { [weak self] in self?.laidOut() }
            view.backgroundColor = .clear
            view.overrideUserInterfaceStyle = .dark
            view.showsVerticalScrollIndicator = false
            // Marges du haut et du bas : 24 points avec celles des lignes (9 points chacune).
            view.contentInset = UIEdgeInsets(top: 15, left: 0, bottom: 15, right: 0)
            view.delegate = self
            self.view = view

            let lines = lyrics.lines
            let copyright = lyrics.copyright
            let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
                cell.backgroundConfiguration = .clear()
                cell.accessibilityTraits = []
                cell.accessibilityCustomActions = nil
                switch item {
                case .genius:
                    // Paroles de secours : Genius précisé en haut, comme sur ordinateur (rien pour celles de Deezer).
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(tr("Paroles : Genius")).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.margins(.horizontal, 0).margins(.vertical, 9)
                    cell.contentView.alpha = 1
                case .copyright:
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(copyright).font(.caption).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }.margins(.horizontal, 0).margins(.vertical, 9)
                    cell.contentView.alpha = 1
                case .line(let i):
                    let text = lines[i].text
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : text)
                            .font(.title2.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.margins(.horizontal, 0).margins(.vertical, 9)
                    cell.contentView.alpha = self?.alpha(i) ?? 1
                    // Paroles synchronisées : un appui va à cette ligne (annoncé comme un bouton).
                    if self?.synced == true { cell.accessibilityTraits = .button }
                    cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: tr("Partager en image")) { [weak self] _ in
                        MainActor.assumeIsolated { self?.onShare(i) }
                        return true
                    }]
                }
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { view, path, item in
                view.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
            snapshot.appendSections([0])
            if lyrics.fromGenius { snapshot.appendItems([.genius]) }
            snapshot.appendItems(lines.indices.map { .line($0) })
            if !copyright.isEmpty { snapshot.appendItems([.copyright]) }
            dataSource.apply(snapshot, animatingDifferences: false)

            // Appui long : partager cette ligne (et d'autres) en image avec la pochette.
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.4
            view.addGestureRecognizer(press)
            return view
        }

        /// Ligne en cours en blanc, les autres atténuées ; non synchronisées : toutes en blanc.
        private func alpha(_ i: Int) -> CGFloat { !synced || i == active ? 1 : 0.35 }

        func show(_ i: Int) {
            guard i != active else { return }
            let old = active
            active = i
            fade(old)
            fade(i)
            guard i >= 0, Date() >= readingUntil else { return }
            // Ouverture des paroles (aucune ligne avant) : directement à la bonne ligne, sans défiler depuis le début.
            center(i, animated: old >= 0)
        }

        private func fade(_ i: Int) {
            guard i >= 0, let path = dataSource.indexPath(for: .line(i)), let cell = view?.cellForItem(at: path) else { return }
            let alpha = alpha(i)
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { cell.contentView.alpha = alpha }
        }

        /// Ligne amenée au centre (bornée au début et à la fin du texte).
        private func center(_ i: Int, animated: Bool) {
            guard let view, view.bounds.height > 0, let path = dataSource.indexPath(for: .line(i)) else {
                pendingCenter = i
                return
            }
            if !animated {
                // Lignes pas encore mesurées (hauteur estimée) : d'abord à peu près, puis exactement une fois mesurées.
                view.scrollToItem(at: path, at: .centeredVertically, animated: false)
                view.layoutIfNeeded()
            }
            guard let frame = view.layoutAttributesForItem(at: path)?.frame else { return }
            let inset = view.adjustedContentInset
            let bottom = max(-inset.top, view.contentSize.height + inset.bottom - view.bounds.height)
            let y = min(max(frame.midY - view.bounds.height / 2, -inset.top), bottom)
            view.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }

        /// Liste à sa taille : la ligne en cours, demandée avant, est centrée (hors de la mise en page en cours).
        private func laidOut() {
            guard let i = pendingCenter, let view, view.bounds.height > 0 else { return }
            pendingCenter = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active == i else { return }
                self.center(i, animated: false)
            }
        }

        @objc private func pressed(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began, let view, let path = view.indexPathForItem(at: press.location(in: view)),
                  case let .line(i) = dataSource.itemIdentifier(for: path) else { return }
            onShare(i)
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt path: IndexPath) -> Bool {
            guard synced, case .line = dataSource.itemIdentifier(for: path) else { return false }
            return true
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
            collectionView.deselectItem(at: path, animated: false)
            guard case let .line(i) = dataSource.itemIdentifier(for: path) else { return }
            onTap(i)
        }

        // Texte déplacé à la main : le suivi reprend 4 s après le lâcher (on peut lire la suite tranquillement).
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { readingUntil = .distantFuture }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            readingUntil = Date().addingTimeInterval(4)
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
                                if let label = credits.label { LabeledContent(tr("Label"), value: label) }
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
                let url = player.mp3Cover(track) ?? player.coverFixes[track.id] ?? track.coverUrl
                if let url, let c = await CoverLoader.shared.color(url: url) { tint = Color(uiColor: c) }
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
            CoverView(url: player.mp3Cover(track) ?? player.coverFixes[track.id] ?? track.coverUrl, side: 150, radius: 14)
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

/// Menu du titre du grand lecteur (artistes, album, crédits, lien) : un bouton d'iOS invisible, posé sur le titre, dont
/// l'appui ouvre le menu. Rien n'est dessiné par SwiftUI autour : avant, avec un `Menu` SwiftUI, iOS 26 laissait un
/// rectangle gris sur la zone d'appui une fois le menu refermé. Le menu est construit à l'ouverture, pour le titre en cours.
private struct TitleMenuButton: UIViewRepresentable {
    let track: Track
    let player: Player

    @MainActor
    final class Coordinator {
        var track: Track?
        weak var player: Player?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = PointPreviewButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { done in
            MainActor.assumeIsolated { done(Self.items(coordinator)) }
        }])
        button.accessibilityLabel = tr("Plus d'actions")
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.track = track
        context.coordinator.player = player
    }

    @MainActor
    private static func items(_ c: Coordinator) -> [UIMenuElement] {
        guard let t = c.track, let player = c.player else { return [] }
        var open: [UIMenuElement] = t.artistLinks.map { a in
            UIAction(title: a.name, image: UIImage(systemName: "music.mic")) { [weak player] _ in
                MainActor.assumeIsolated { player?.navigate(.detail(kind: "artist", id: a.id, title: a.name)) }
            }
        }
        if t.albumId != 0 {
            open.append(UIAction(title: t.album, image: UIImage(systemName: "square.stack")) { [weak player] _ in
                MainActor.assumeIsolated { player?.navigate(.detail(kind: "album", id: t.albumId, title: t.album)) }
            })
        }
        var more: [UIMenuElement] = [UIAction(title: tr("Voir les crédits"), image: UIImage(systemName: "person.2")) { [weak player] _ in
            MainActor.assumeIsolated { player?.creditsTrack = t }
        }]
        if let url = t.shareURL {
            more.append(UIAction(title: tr("Copier le lien"), image: UIImage(systemName: "link")) { [weak player] _ in
                MainActor.assumeIsolated { player?.copyLink(url) }
            })
        }
        return open + [UIMenu(options: .displayInline, children: more)]
    }
}

/// Bouton dont le menu sort d'un point invisible (coin haut gauche) et y retourne. Avant, iOS faisait sortir le menu de
/// tout le bouton et le refermait dans un rectangle gris de sa taille, visible un instant sur le titre.
private final class PointPreviewButton: UIButton {
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        pointPreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        pointPreview()
    }

    private func pointPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        dot.backgroundColor = .clear
        return UITargetedPreview(view: dot, parameters: parameters, target: UIPreviewTarget(container: self, center: CGPoint(x: 1, y: 1)))
    }
}

/// Icône Aléatoire dessinée (deux flèches qui se croisent, comme celle d'iOS), pour pouvoir l'animer vraiment : à
/// chaque appui, les flèches se démêlent (leurs départs se rejoignent, elles s'écartent en fourche) puis se
/// recroisent avec un petit ressort, comme l'icône de « Répéter » qui se transforme. Dessin dans un carré de 24 x 24,
/// mis à l'échelle.
struct ShuffleIcon: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // « Réduire les animations » : l'icône reste croisée, sans animation.
        KeyframeAnimator(initialValue: 1.0, trigger: on && !reduceMotion) { cross in
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
    /// `grouped` : un seul contour pour tout le bloc, calculé une fois (moins de rendus hors écran à chaque image quand
    /// on glisse le lecteur). Seulement sans vue UIKit dedans : le bloc des commandes, qui contient le bouton AirPlay
    /// (vue UIKit), garde un contour par élément pour que ce bouton s'affiche et réponde normalement.
    @ViewBuilder
    func legible(grouped: Bool = false) -> some View {
        if grouped {
            compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: 1.5)
                .shadow(color: .black.opacity(0.2), radius: 6)
        } else {
            shadow(color: .black.opacity(0.45), radius: 1.5)
                .shadow(color: .black.opacity(0.2), radius: 6)
        }
    }
}
