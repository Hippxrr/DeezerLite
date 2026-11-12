import PhotosUI
import SwiftUI

/// Pose le mode choisi sur la fenêtre dès qu'elle existe, avant le premier affichage.
private struct WindowStyle: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = ThemeStore.shared.appearance.style
        }
    }

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}
}

/// Au lancement : le logo de l'écran de démarrage d'iOS, repris exactement au même endroit. Il se contracte un instant,
/// puis file vers l'avant en s'effaçant pendant que le fond disparaît sur l'app, déjà remplie (les copies du
/// téléphone sont lues pendant ce temps) et immobile. Moins d'une seconde, jamais bloqué.
/// « Réduire les animations » : simple fondu.
private struct LaunchCover: View {
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let done: () -> Void
    @State private var logoScale: CGFloat = 1
    @State private var logoOpacity: Double = 1
    @State private var logoBlur: CGFloat = 0
    @State private var backgroundOpacity: Double = 1
    @State private var coverOpacity: Double = 1
    @State private var leaving = false

    /// Même taille et même place que sur l'écran de démarrage d'iOS (image centrée, 120 points).
    private var logo: some View {
        Image("LaunchLogo").resizable().frame(width: 120, height: 120)
    }

    var body: some View {
        ZStack {
            Color("LaunchBackground").opacity(backgroundOpacity)
            logo.scaleEffect(logoScale).blur(radius: logoBlur).opacity(logoOpacity)
        }
        .ignoresSafeArea()
        .opacity(coverOpacity)
        .allowsHitTesting(!leaving)
        .accessibilityHidden(true)
        .task {
            let start = Date()
            // Copies lues, et au moins un court instant pour que l'animation ne paraisse pas saccadée. Au plus 1 s.
            while Date().timeIntervalSince(start) < 1, !player.launchReady || Date().timeIntervalSince(start) < 0.15 {
                try? await Task.sleep(for: .milliseconds(30))
            }
            leaving = true
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { coverOpacity = 0 }
                try? await Task.sleep(for: .milliseconds(320))
                done()
                return
            }
            // 1. Le cœur prend son élan : il se contracte.
            withAnimation(.easeInOut(duration: 0.2)) { logoScale = 0.86 }
            try? await Task.sleep(for: .milliseconds(200))
            // 2. Il file vers l'avant (vers soi) en se floutant et s'efface ; le fond disparaît juste derrière lui.
            // L'app ne bouge pas : réduite pendant l'animation, la barre d'onglets se décalait puis sautait en place.
            withAnimation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.45)) {
                logoScale = 2.4
                logoBlur = 6
            }
            withAnimation(.easeIn(duration: 0.3)) { logoOpacity = 0 }
            withAnimation(.easeOut(duration: 0.4).delay(0.05)) { backgroundOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(470))
            done()
        }
    }
}

struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(\.scenePhase) private var phase
    /// Animation de lancement : seulement quand l'app s'ouvre à l'écran (pas lancée en arrière-plan par CarPlay ou l'audio).
    @State private var launchCover = UIApplication.shared.applicationState != .background

    var body: some View {
        Group {
            switch player.loggedIn {
            case nil: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case false?: LoginView()
            case true?: MainTabs()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .background(WindowStyle())
        .onChange(of: phase) { _, now in
            if now == .active { ThemeStore.applyStyle(ThemeStore.shared.appearance.style) }
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) {
            // Petit message de confirmation (ajouté à la file, à une playlist…) : disparaît seul.
            if let text = player.toast {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .surface(Capsule(), interactive: false, material: true)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.top, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(text)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.toast)
        .overlay {
            if launchCover {
                LaunchCover { launchCover = false }
            }
        }
        .alert("Deezer Lite", isPresented: Binding(get: { player.message != nil }, set: { if !$0 { player.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.message ?? "")
        }
    }
}

struct LoginView: View {
    @Environment(Player.self) private var player
    @State private var arl = ""
    @State private var busy = false
    @State private var web = false
    @State private var showArl = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.background, Theme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 96, height: 96)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 24, y: 10)
                VStack(spacing: 6) {
                    Text("Deezer Lite").font(.largeTitle.bold())
                    Text(tr("Ta musique Deezer, légère et rapide.")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { web = true } label: {
                    HStack {
                        if busy { ProgressView().tint(Theme.onAccent) }
                        Text(busy ? tr("Connexion…") : tr("Se connecter avec Deezer")).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.pressable)
                .disabled(busy)

                // Autre moyen : coller le cookie « arl » (comme sur la version bureau).
                VStack(spacing: 12) {
                    Button { withAnimation(.snappy) { showArl.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text(tr("Utiliser un cookie arl"))
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showArl ? 180 : 0))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    if showArl {
                        HStack(spacing: 10) {
                            SecureField("arl", text: $arl)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .onSubmit(loginWithArl)
                            Button(action: loginWithArl) { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                                .disabled(arl.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                        .padding(14)
                        .surface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.bottom, 12)
            }
            .padding(24)
        }
        .sheet(isPresented: $web) {
            WebLoginSheet { cookie in login(cookie) }
        }
    }

    private func loginWithArl() { login(arl) }

    private func login(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !busy else { return }
        busy = true
        Task {
            await player.login(arl: value)
            busy = false
            arl = "" // l'arl ne reste pas dans un champ de l'interface
        }
    }
}

/// Les trois onglets ; chacun a sa propre pile de navigation et le mini-lecteur au-dessus de la barre d'onglets.
struct MainTabs: View {
    @Environment(Player.self) private var player
    @State private var tab = 0
    @State private var picked: PhotosPickerItem?
    @State private var lovedName = ""
    /// Photo choisie, à cadrer avant de devenir la pochette.
    @State private var crop: CoverCrop?
    /// Réglages > Apparence : onglets sans leur nom, icônes seules.
    @AppStorage("tabLabelsHidden") private var tabLabelsHidden = false
    /// Réglages > Apparence : barre de l'app sur toute la largeur, sinon celle d'iOS.
    @AppStorage("tabBarFull") private var tabBarFull = true
    /// Ancienne valeur gardée tant que les Réglages sont ouverts : changer de barre reconstruit les pages, et la feuille
    /// des Réglages (ouverte depuis l'une d'elles) se refermait aussitôt. La nouvelle barre arrive à leur fermeture.
    @State private var barFullHeld: Bool?
    private var barFullShown: Bool { barFullHeld ?? tabBarFull }
    /// Barre de l'app réduite par le défilement.
    @State private var barCollapsed = false
    /// Onglets déjà ouverts : une page n'est construite qu'à sa première visite.
    @State private var visited: Set<Int> = [0]
    /// Dernier onglet ouvert autre que la recherche.
    @State private var lastPage = 0
    /// Nouvel appui sur l'accueil ou la bibliothèque déjà ouverts : retour à leur première page.
    @State private var homePop = 0
    @State private var libraryPop = 0
    /// Nouvel appui sur l'onglet Recherche déjà ouvert : ouvre le clavier.
    @State private var searchFocus = 0

    /// Onglet choisi. iOS passe aussi par ici quand on rappuie sur l'onglet déjà ouvert.
    private var selection: Binding<Int> {
        Binding(get: { tab }, set: { new in
            if new == 1 && tab == 1 { searchFocus += 1 }
            tab = new
        })
    }

    private static var tabTitles: [String?] { [tr("Accueil"), tr("Recherche"), tr("Bibliothèque")] }

    /// Change le nom des onglets directement sur la barre d'iOS : SwiftUI ne relit pas le contenu de `tabItem` une fois
    /// la barre affichée, et il fallait relancer l'app.
    private static func applyTabTitles(_ titles: [String?]) {
        func tabBar(in controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let found = controller as? UITabBarController { return found }
            return controller.children.lazy.compactMap { tabBar(in: $0) }.first
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            guard let items = tabBar(in: window.rootViewController)?.tabBar.items else { continue }
            for (item, title) in zip(items, titles) { item.title = title }
        }
    }

    /// Contenu d'un onglet : l'icône, et son nom sauf si l'option le masque (VoiceOver le lit toujours).
    @ViewBuilder
    private func tabLabel(_ title: String, _ icon: Image) -> some View {
        icon.accessibilityLabel(title)
        if !tabLabelsHidden { Text(title) }
    }

    /// Jusqu'à iOS 26.0 : onglets classiques, le mini-lecteur est posé par-dessus (voir `body`).
    private var classicTabs: some View {
        TabView(selection: selection) {
            TabStack(active: tab == 0) { HomeView() }
                .tabItem { tabLabel(tr("Accueil"), Image(uiImage: TabIcons.home)) }
                .tag(0)
            TabStack(active: tab == 1, popRequest: searchFocus) { SearchView(focusRequest: searchFocus) }
                .tabItem { tabLabel(tr("Recherche"), Image(systemName: "magnifyingglass")) }
                .tag(1)
            TabStack(active: tab == 2) { LibraryView() }
                .tabItem { tabLabel(tr("Bibliothèque"), Image(uiImage: TabIcons.library)) }
                .tag(2)
        }
        .onChange(of: tabLabelsHidden) { _, hidden in Self.applyTabTitles(hidden ? [nil, nil, nil] : Self.tabTitles) }
        // Autre langue : le nom des onglets suit tout de suite.
        .onChange(of: LanguageStore.shared.current) { if !tabLabelsHidden { Self.applyTabTitles(Self.tabTitles) } }
    }

    #if compiler(>=6.2.1)
    /// iOS 26.1 et plus : le mini-lecteur fait partie de la barre. En descendant dans une page, elle se réduit : l'onglet
    /// ouvert à gauche, le mini-lecteur au milieu, la recherche à droite.
    @available(iOS 26.1, *)
    private var barTabs: some View {
        TabView(selection: selection) {
            Tab(value: 0) {
                TabStack(active: tab == 0) { HomeView() }
            } label: {
                tabLabel(tr("Accueil"), Image(uiImage: TabIcons.home))
            }
            Tab(value: 2) {
                TabStack(active: tab == 2) { LibraryView() }
            } label: {
                tabLabel(tr("Bibliothèque"), Image(uiImage: TabIcons.library))
            }
            Tab(value: 1, role: .search) {
                TabStack(active: tab == 1, popRequest: searchFocus) { SearchView(focusRequest: searchFocus) }
            } label: {
                tabLabel(tr("Recherche"), Image(systemName: "magnifyingglass"))
            }
        }
        // Réduite en défilant seulement quand le mini-lecteur est là (elle lui fait de la place) : sans titre en cours,
        // la barre restait sinon réduite à l'onglet ouvert, bibliothèque cachée, pour rien.
        .tabBarMinimizeBehavior(player.current != nil || player.loading ? .onScrollDown : .never)
        .tabViewBottomAccessory(isEnabled: player.current != nil || player.loading) {
            BarMiniPlayer().environment(player)
        }
    }
    #endif

    /// Onglet choisi dans la barre de l'app : un nouvel appui revient à la première page (et ouvre le clavier sur la recherche).
    private func selectOwn(_ new: Int) {
        if new == tab {
            switch new {
            case 0: homePop += 1
            case 1: searchFocus += 1
            default: libraryPop += 1
            }
        }
        visited.insert(new)
        if new != 1 { lastPage = new }
        tab = new
        barCollapsed = false
    }

    /// Page d'un onglet : gardée en place une fois ouverte, cachée quand un autre onglet est affiché.
    private func ownPage<Page: View>(_ id: Int, _ page: Page) -> some View {
        page
            .opacity(tab == id ? 1 : 0)
            .allowsHitTesting(tab == id)
            .accessibilityHidden(tab != id)
    }

    /// Barre de l'app : les pages restent en place l'une sur l'autre, et la barre est posée par-dessus. Elle ignore le
    /// clavier, qui la recouvre simplement.
    private var ownTabs: some View {
        ZStack {
            ownPage(0, TabStack(active: tab == 0, popRequest: homePop) { HomeView() })
            if visited.contains(1) || tab == 1 {
                ownPage(1, TabStack(active: tab == 1, popRequest: searchFocus) { SearchView(focusRequest: searchFocus) })
            }
            if visited.contains(2) || tab == 2 {
                ownPage(2, TabStack(active: tab == 2, popRequest: libraryPop) { LibraryView() })
            }
            VStack {
                Spacer()
                GlassTabBar(tab: tab, lastPage: lastPage, collapsed: barCollapsed, labelsHidden: tabLabelsHidden,
                            onSelect: { selectOwn($0) }, onExpand: { barCollapsed = false })
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard)
        }
        .background(ScrollCollapse(active: !player.showFullPlayer && (player.current != nil || player.loading),
                                   collapsed: barCollapsed) { barCollapsed = $0 })
        .onChange(of: player.current == nil && !player.loading) { _, empty in if empty { barCollapsed = false } }
    }

    @ViewBuilder
    private var tabs: some View {
        #if compiler(>=6.2.1)
        if #available(iOS 26.1, *) {
            if barFullShown {
                ownTabs
            } else {
                barTabs
            }
        } else {
            classicTabs
        }
        #else
        classicTabs
        #endif
    }

    var body: some View {
        ZStack {
            // Grand lecteur ouvert par-dessus : VoiceOver ne lit plus les pages ni le mini-lecteur cachés dessous.
            tabs.accessibilityHidden(player.showFullPlayer)
                // Ni appui ni effet de verre sur les pages tant que le grand lecteur est ouvert (ou en train de se
                // fermer) : le verre « interactif » des cartes réagissait au doigt à travers le lecteur (iOS le fait
                // réagir même sous ce qui est posé dessus), et l'effet d'appui apparaissait sur la page quand il descendait.
                .allowsHitTesting(!player.showFullPlayer)
                .environment(\.glassReactsToTouch, !player.showFullPlayer)
            // Mini-lecteur posé au-dessus de la barre d'onglets, sous le grand lecteur. Il ignore le clavier :
            // celui-ci le recouvre simplement, sans rien déplacer ni retirer (le baisser en faisant défiler reste fluide).
            if !MiniPlayerMetrics.inTabBar {
                VStack {
                    Spacer()
                    if player.current != nil || player.loading {
                        MiniPlayer()
                            .padding(.bottom, MiniPlayerMetrics.tabBar)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(.keyboard)
                .accessibilityHidden(player.showFullPlayer)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.current == nil && !player.loading)
            }
            // Le lecteur plein écran reste en place, hors de l'écran quand il est fermé : l'ouvrir ou le fermer
            // n'est qu'un déplacement (rien à construire), et il suit le doigt pendant le geste.
            FullPlayerContainer().zIndex(1)
        }
        // Pochette perso : la photo choisie est lue en mémoire, cadrée à la main, puis enregistrée (rien d'autre ne reste).
        .photosPicker(isPresented: Binding(get: { player.pickingCover }, set: { player.pickingCover = $0 }), selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item, let card = player.coverTarget else { return }
            picked = nil
            player.coverTarget = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let image = await Task.detached(priority: .userInitiated) { CoverCropView.load(data) }.value
                guard let image else { player.showToast(tr("Image illisible : choisis une autre photo."), seconds: 4); return }
                crop = CoverCrop(card: card, image: image)
            }
        }
        .fullScreenCover(item: $crop) { c in
            CoverCropView(image: c.image) { data in
                Task { await player.setCustomCover(c.card, data: data) }
            }
        }
        .alert(tr("Renommer"), isPresented: Binding(get: { player.renamingLoved }, set: { player.renamingLoved = $0 })) {
            TextField(tr(Player.defaultLovedTitle), text: $lovedName)
            Button(tr("Annuler"), role: .cancel) {}
            Button("OK") { player.setLovedTitle(lovedName) }
        } message: {
            Text(tr("Seulement sur ce téléphone. Laisse vide pour revenir à « %@ ».", tr(Player.defaultLovedTitle)))
        }
        .onChange(of: player.renamingLoved) { _, open in if open { lovedName = player.lovedTitle } }
        // « Barre d'onglets complète » changée dans les Réglages : la barre change à leur fermeture (voir `barFullShown`).
        .onChange(of: tabBarFull) { old, _ in if player.settingsOpen, barFullHeld == nil { barFullHeld = old } }
        .onChange(of: player.settingsOpen) { _, open in if !open { barFullHeld = nil } }
        // Compte Famille : « Qui écoute ? » à la première connexion (fermée sans choisir : le profil ouvert est gardé).
        .sheet(isPresented: Binding(get: { player.choosingProfile && !player.settingsOpen }, set: { player.choosingProfile = $0 }), onDismiss: { player.keepCurrentProfile() }) {
            ProfilePicker().environment(player).presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { player.creditsTrack }, set: { player.creditsTrack = $0 })) { track in
            CreditsView(track: track).environment(player).presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { player.playlistTrack }, set: { player.playlistTrack = $0 })) { track in
            PlaylistChooser(track: track).environment(player).presentationDetents([.medium, .large])
        }
        .confirmationDialog(tr("Supprimer la playlist ?"),
                            isPresented: Binding(get: { player.deletingPlaylist != nil }, set: { if !$0 { player.deletingPlaylist = nil } }),
                            titleVisibility: .visible, presenting: player.deletingPlaylist) { card in
            Button(tr("Supprimer"), role: .destructive) { Task { await player.deletePlaylist(card) } }
        } message: { card in
            Text(tr("« %@ » sera supprimée de ton compte Deezer. Cette action est définitive.", card.title))
        }
    }
}

enum MiniPlayerMetrics {
    /// Mini-lecteur placé dans la barre d'onglets par iOS (26.1 et plus), et non posé par-dessus par l'app.
    static var inTabBar: Bool {
        #if compiler(>=6.2.1)
        if #available(iOS 26.1, *) { return true }
        #endif
        return false
    }
    /// Hauteur de la barre d'onglets du système : flottante et plus haute depuis iOS 26.
    static var tabBar: CGFloat {
        if #available(iOS 26.0, *) { return 62 }
        return 49
    }
    /// Place laissée sous le contenu des pages pour que la fin des listes ne passe pas sous le mini-lecteur
    /// (sa hauteur, 62, plus une marge : le dernier titre s'arrête au-dessus de lui).
    static let mini: CGFloat = 84
}

struct TabStack<Content: View>: View {
    @Environment(Player.self) private var player
    @State private var path = NavigationPath()
    let active: Bool
    /// Change : retour à la première page de l'onglet.
    var popRequest = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .miniPlayerSpace()
                .background(EdgeOnlyBack())
                .pageBackground()
                .navigationDestination(for: Route.self) { DetailView(route: $0).miniPlayerSpace().pageBackground() }
                .navigationDestination(for: LibrarySection.self) { LibrarySectionView(section: $0).miniPlayerSpace().pageBackground() }
        }
        .environment(\.openRoute) { path.append($0) }
        // Page demandée depuis le lecteur plein écran : ouverte dans l'onglet affiché.
        .onChange(of: player.requestedRoute) { _, route in
            guard active, let route else { return }
            path.append(route)
            player.requestedRoute = nil
        }
        // Autre profil : les pages ouvertes étaient celles du profil d'avant.
        .onChange(of: player.profileEpoch) { path = NavigationPath() }
        .onChange(of: popRequest) { path = NavigationPath() }
    }
}

/// Espace vide sous une page, à la hauteur du mini-lecteur (posé par-dessus dans MainTabs) : la fin des listes
/// reste accessible. Posé sur chaque page : depuis iOS 26, une page ouverte dans la pile (album, playlist)
/// n'hérite plus de celui posé sur la pile elle-même, et son dernier titre restait caché.
private struct MiniPlayerSpace: ViewModifier {
    @Environment(Player.self) private var player
    @AppStorage("tabBarFull") private var tabBarFull = true

    func body(content: Content) -> some View {
        let mini = player.current != nil || player.loading
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if MiniPlayerMetrics.inTabBar {
                // Barre de l'app : la place est à laisser ici. Barre d'iOS : c'est elle qui s'en charge.
                if tabBarFull { Color.clear.frame(height: GlassBarMetrics.pageSpace(mini: mini)) }
            } else if mini {
                Color.clear.frame(height: MiniPlayerMetrics.mini)
            }
        }
    }
}

extension View {
    func miniPlayerSpace() -> some View { modifier(MiniPlayerSpace()) }
}
