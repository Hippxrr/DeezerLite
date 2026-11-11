import SwiftUI

/// Mesures de la barre du bas (points).
enum GlassBarMetrics {
    static let barHeight: CGFloat = 62
    /// Mini-lecteur, et ronds de la barre réduite.
    static let small: CGFloat = 48
    static let gap: CGFloat = 9
    static let side: CGFloat = 22
    static let bottom: CGFloat = 21
    /// Écart entre les ronds et le mini-lecteur quand la barre est réduite.
    static let foldedGap: CGFloat = 10

    /// Place à laisser sous les pages, au-dessus de la zone sûre du bas : la fin des listes reste accessible. La barre est
    /// posée à `bottom` du bord de l'écran ; la zone sûre vaut 34 points sur les iPhone sans bouton, 0 avec (iPhone SE),
    /// où la fin des listes restait cachée sous la barre.
    @MainActor
    static func pageSpace(mini: Bool) -> CGFloat {
        let bar = max(0, barHeight + bottom - safeBottom) + 8
        return mini ? bar + small + gap : bar
    }

    @MainActor
    private static var safeBottom: CGFloat {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.safeAreaInsets.bottom ?? 34
    }
}

/// Barre du bas de l'app (iOS 26.1 et plus, option « Barre d'onglets complète ») : toute la largeur, avec ou sans titre en
/// cours. Tout est posé à une position calculée et bouge dans une seule animation : quand elle se réduit, l'onglet ouvert,
/// le mini-lecteur et la loupe vont chacun à leur place en même temps, sans rien recréer.
struct GlassTabBar: View {
    @Environment(Player.self) private var player
    @Environment(\.colorScheme) private var scheme
    /// 0 = accueil, 1 = recherche, 2 = bibliothèque.
    let tab: Int
    /// Dernier onglet ouvert autre que la recherche : celui montré à gauche quand la barre est réduite sur la recherche.
    let lastPage: Int
    let collapsed: Bool
    let labelsHidden: Bool
    let onSelect: (Int) -> Void
    let onExpand: () -> Void

    /// Ordre à l'écran : accueil, bibliothèque, recherche.
    private static let order = [0, 2, 1]

    private var hasMini: Bool { player.current != nil || player.loading }
    private var folded: Bool { collapsed && hasMini }
    private var leftTab: Int { tab == 1 ? lastPage : tab }

    private func title(_ id: Int) -> String {
        switch id {
        case 0: tr("Accueil")
        case 1: tr("Recherche")
        default: tr("Bibliothèque")
        }
    }

    @ViewBuilder
    private func icon(_ id: Int) -> some View {
        switch id {
        case 0: Image(uiImage: TabIcons.home).renderingMode(.template)
        case 2: Image(uiImage: TabIcons.library).renderingMode(.template)
        default: Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
        }
    }

    private func item(_ id: Int) -> some View {
        VStack(spacing: 2) {
            icon(id).frame(width: 28, height: 28)
            if !labelsHidden && !folded {
                Text(title(id)).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .foregroundStyle(id == tab ? Theme.accent : Color.primary)
    }

    /// Un onglet, à sa place dans la barre entière ou réduite.
    private func button(_ id: Int, slot: Int, width: CGFloat) -> some View {
        let third = width / 3
        let isSearch = id == 1
        let visible = !folded || isSearch || id == leftTab
        // Seuls l'onglet gardé et la loupe se déplacent. Celui qui disparaît reste à sa place et s'efface.
        let moves = folded && visible
        let size = moves ? GlassBarMetrics.small : third
        let x = !moves ? third * CGFloat(slot) : isSearch ? width - GlassBarMetrics.small : 0
        return Button {
            if folded && !isSearch { onExpand() } else { onSelect(id) }
        } label: {
            item(id)
                .frame(width: size, height: moves ? GlassBarMetrics.small : GlassBarMetrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title(id))
        .accessibilityAddTraits(id == tab ? .isSelected : [])
        // Elle réapparaît une fois le mini-lecteur remonté (il passait dessus en même temps).
        .animation(.easeOut(duration: 0.15).delay(visible && !isSearch ? 0.12 : 0)) { $0.opacity(visible ? 1 : 0) }
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .offset(x: x)
    }

    /// Fonds de la barre : bulle, rond de la loupe, pastille de l'onglet ouvert.
    private func bar(width: CGFloat) -> some View {
        let third = width / 3
        let slot = Self.order.firstIndex(of: tab) ?? 0
        return ZStack(alignment: .bottomLeading) {
            // Bulle des onglets : toute la largeur, ou un rond à gauche.
            Color.clear
                .frame(width: folded ? GlassBarMetrics.small : width, height: folded ? GlassBarMetrics.small : GlassBarMetrics.barHeight)
                .surface(Capsule(), interactive: false, material: true)
            // Rond de la loupe, seulement quand la barre est réduite.
            Color.clear
                .frame(width: GlassBarMetrics.small, height: GlassBarMetrics.small)
                .surface(Circle(), interactive: false, material: true)
                .opacity(folded ? 1 : 0)
                .scaleEffect(folded ? 1 : 0.6)
                .offset(x: width - GlassBarMetrics.small)
            // Onglet ouvert.
            Capsule()
                .fill(Color.black.opacity(scheme == .dark ? 0.4 : 0.08))
                .frame(width: third - 10, height: GlassBarMetrics.barHeight - 12)
                // Pendant le trajet, elle s'étire comme une goutte puis reprend sa forme.
                .keyframeAnimator(initialValue: CGFloat(1), trigger: tab) { view, stretch in
                    view.scaleEffect(x: stretch, y: 2 - stretch)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1.16, duration: 0.16)
                        SpringKeyframe(1, duration: 0.34, spring: .bouncy(duration: 0.34, extraBounce: 0.1))
                    }
                }
                .offset(x: third * CGFloat(slot) + 5, y: -6)
                .opacity(folded ? 0 : 1)
        }
    }

    /// Onglets, posés au-dessus du mini-lecteur : quand il monte ou descend, son verre passait sur les icônes et en
    /// montrait un reflet flou (une maison blanche quelques instants à l'ancienne place de l'onglet).
    private func buttons(width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { index, id in
                button(id, slot: index, width: width)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let round = GlassBarMetrics.small + GlassBarMetrics.foldedGap
            ZStack(alignment: .bottomLeading) {
                bar(width: width)
                if hasMini {
                    MiniPlayer(inBar: true, compact: folded)
                        .frame(width: folded ? width - round * 2 : width, height: GlassBarMetrics.small)
                        .surface(Capsule(), material: true)
                        .offset(x: folded ? round : 0, y: folded ? 0 : -(GlassBarMetrics.barHeight + GlassBarMetrics.gap))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                buttons(width: width)
            }
            .frame(width: width, height: geo.size.height, alignment: .bottomLeading)
        }
        .frame(height: GlassBarMetrics.barHeight + GlassBarMetrics.gap + GlassBarMetrics.small)
        .padding(.horizontal, GlassBarMetrics.side)
        .padding(.bottom, GlassBarMetrics.bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: folded)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasMini)
        // Changement d'onglet : la pastille glisse d'un onglet à l'autre, en souplesse.
        .animation(.spring(response: 0.46, dampingFraction: 0.8), value: tab)
    }
}

/// Réduit la barre quand on descend dans une page et la rouvre seulement de retour en haut, sans rien ajouter aux pages :
/// un geste posé sur la fenêtre repère la liste sous le doigt, puis sa position est suivie (lancer compris). Ce geste ne
/// prend aucun appui et ne gêne donc ni les listes ni les boutons.
struct ScrollCollapse: UIViewRepresentable {
    let active: Bool
    let collapsed: Bool
    let onChange: (Bool) -> Void

    /// Défilement à faire vers le bas, depuis le début du geste, avant de réduire la barre.
    private static let threshold: CGFloat = 48

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pan = UIPanGestureRecognizer()
        var onChange: (Bool) -> Void = { _ in }
        var collapsed = false
        private weak var scroll: UIScrollView?
        private var observation: NSKeyValueObservation?
        /// Liste trouvée pour le geste en cours.
        private var found = false
        /// Point le plus haut depuis le début du geste : la descente se mesure à partir de lui.
        private var anchor: CGFloat = 0

        override init() {
            super.init()
            pan.cancelsTouchesInView = false
            pan.delegate = self
        }

        private func scrollsVertically(_ view: UIScrollView) -> Bool {
            let inset = view.adjustedContentInset
            return view.contentSize.height + inset.top + inset.bottom > view.bounds.height + 1
        }

        private func follow(_ view: UIScrollView) {
            anchor = view.contentOffset.y
            guard view !== scroll else { return }
            scroll = view
            observation = view.observe(\.contentOffset) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.scrolled(view) }
            }
        }

        private func set(_ value: Bool) {
            guard value != collapsed else { return }
            collapsed = value
            onChange(value)
        }

        private func scrolled(_ view: UIScrollView) {
            guard pan.isEnabled else { return }
            let y = view.contentOffset.y
            // Haut de la page : la seule façon de retrouver la barre entière en défilant.
            if y <= -view.adjustedContentInset.top + 4 {
                anchor = y
                set(false)
                return
            }
            guard !collapsed else { return }
            if y < anchor { anchor = y }
            if y - anchor > ScrollCollapse.threshold { set(true) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            found = false
            // Une feuille ouverte (Réglages…) défile pour elle-même : la barre dessous ne bouge pas.
            if (gestureRecognizer.view as? UIWindow)?.rootViewController?.presentedViewController != nil { return false }
            var view = touch.view
            while let current = view {
                if let list = current as? UIScrollView, scrollsVertically(list) {
                    follow(list)
                    found = true
                    break
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if !found, let list = other.view as? UIScrollView, other === list.panGestureRecognizer, scrollsVertically(list) {
                follow(list)
                found = true
            }
            return true
        }
    }

    final class Probe: UIView {
        var pan: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let pan else { return }
            pan.view?.removeGestureRecognizer(pan)
            window?.addGestureRecognizer(pan)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.pan = context.coordinator.pan
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.collapsed = collapsed
        context.coordinator.pan.isEnabled = active
    }
}
