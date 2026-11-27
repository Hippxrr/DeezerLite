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

/// Au lancement : le logo de l'écran de démarrage d'iOS, repris exactement au même endroit, pendant que les copies du
/// téléphone sont lues. Puis les barres du cœur se séparent et ondulent comme une onde, se resserrent en une ligne de
/// points en léger arc et s'effacent, pendant que le fond disparaît sur l'app déjà remplie et immobile. Avant : le cœur se
/// contractait puis filait vers l'avant en se floutant. Moins d'une seconde, jamais bloqué.
/// « Réduire les animations » : simple fondu.
private struct LaunchCover: View {
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let done: () -> Void
    /// 0 : le logo tel quel ; 1 : barres séparées qui ondulent ; 2 : ligne de points.
    @State private var phase = 0
    @State private var logoOpacity: Double = 1
    @State private var backgroundOpacity: Double = 1
    @State private var coverOpacity: Double = 1
    @State private var leaving = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").opacity(backgroundOpacity)
            LaunchBars(phase: phase).opacity(logoOpacity)
        }
        .ignoresSafeArea()
        .opacity(coverOpacity)
        .allowsHitTesting(!leaving)
        .accessibilityHidden(true)
        .task {
            let start = Date()
            // Copies lues, et au moins un court instant pour que l'animation ne paraisse pas saccadée. Au plus 1 s.
            while Date().timeIntervalSince(start) < 1, !player.launchReady || Date().timeIntervalSince(start) < 0.15 {
                // Annulée : l'écran de lancement est retiré tout de suite (jamais laissé par-dessus l'app). Avant, l'erreur
                // était ignorée et la boucle tournait à vide jusqu'à 1 s.
                guard (try? await Task.sleep(for: .milliseconds(30))) != nil else { done(); return }
            }
            leaving = true
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { coverOpacity = 0 }
                try? await Task.sleep(for: .milliseconds(320))
                done()
                return
            }
            // 1. Les barres se séparent et ondulent.
            withAnimation(.easeOut(duration: 0.18)) { phase = 1 }
            try? await Task.sleep(for: .milliseconds(180))
            // 2. Elles se resserrent en une ligne de points ; l'app apparaît derrière.
            withAnimation(.easeIn(duration: 0.2)) { phase = 2 }
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) { backgroundOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(200))
            // 3. Les points s'effacent.
            withAnimation(.easeOut(duration: 0.15)) { logoOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(170))
            done()
        }
    }
}

/// Le logo (120 points, comme l'écran de démarrage d'iOS) redessiné en ses 9 barres ovales (mesurées sur l'image), qui
/// bougent chacune seule. Au repos, la vraie image est posée par-dessus : le départ est identique au logo d'iOS.
private struct LaunchBars: View {
    let phase: Int

    /// Centre, largeur et hauteur de chaque barre (points).
    private static let bars: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (3, 35.83, 6.67, 27.67), (14.67, 38.83, 12, 62.33), (26.67, 44.17, 19.67, 88.33), (42.33, 55.5, 18.5, 96.33),
        (59.33, 71.83, 23, 95.67), (76.33, 55.5, 18.5, 96.33), (91.67, 44.17, 19.67, 88.33), (105, 38.83, 12, 62.33),
        (116, 35.83, 6.67, 27.67),
    ]
    /// Onde : hauteur de chaque barre (part de la sienne) quand elles se séparent.
    private static let wave: [CGFloat] = [0.85, 0.6, 0.8, 0.5, 0.7, 0.5, 0.8, 0.6, 0.85]
    /// Ligne de points : hauteur où finit chaque point (le milieu plus bas, en léger arc).
    private static let dotY: [CGFloat] = [52, 56, 60, 64, 68, 64, 60, 56, 52]
    /// Dégradé du logo (relevé sur l'image).
    private static let fill = LinearGradient(colors: [Color(red: 0.72, green: 0.42, blue: 0.98), Color(red: 0.56, green: 0.27, blue: 0.94)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ZStack {
            ForEach(Self.bars.indices, id: \.self) { i in
                let b = Self.bars[i]
                let scaleY = phase == 0 ? 1 : phase == 1 ? Self.wave[i] : 4 / b.h
                Self.fill
                    .mask { Ellipse().frame(width: b.w, height: b.h).position(x: b.x, y: b.y) }
                    .scaleEffect(x: phase == 2 ? 0.4 : 1, y: scaleY, anchor: UnitPoint(x: b.x / 120, y: b.y / 120))
                    .offset(x: phase == 0 ? 0 : CGFloat(i - 4) * 2.5, y: phase == 2 ? Self.dotY[i] - b.y : 0)
            }
            // Image d'iOS au repos, retirée d'un coup au départ (les barres dessous ont la même forme).
            Image("LaunchLogo").resizable()
                .opacity(phase == 0 ? 1 : 0)
                .transaction { $0.animation = nil }
        }
        .frame(width: 120, height: 120)
    }
}

/// Petit message de confirmation (ajouté à la file, à une playlist…) : disparaît seul. Posé sur l'app et aussi sur la
/// feuille des Réglages : posé seulement sur l'app, il restait caché sous elle.
private struct ToastOverlay: ViewModifier {
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
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
                // Sur le message seul : posée sur toute l'app, ce qui changeait en même temps qu'un message (playlist
                // supprimée, erreur de lecture…) s'animait aussi en ressort.
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.toast)
            }
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
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
        .toastOverlay()
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
            // Fond uni (avant : un dégradé de la couleur de l'app).
            Theme.background.ignoresSafeArea()
            // Défilable : sur un petit iPhone (SE), le champ arl passait sous le clavier. Toute la hauteur quand il y a la
            // place (même mise en page qu'avant).
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 22) {
                        Spacer()
                        // Logo de l'app, le même que sur l'écran de lancement (avant : une icône « vague » du système).
                        Image("LaunchLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 110, height: 110)
                            .accessibilityHidden(true)
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
                                        .accessibilityLabel(tr("Se connecter"))
                                }
                                .padding(14)
                                .surface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .padding(24)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
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
    /// MP3 choisi (copie pour l'app), lu une fois le sélecteur fermé.
    @State private var pickedMp3: URL?
    @State private var mp3Name = ""
    /// Réglages > Apparence : onglets sans leur nom, icônes seules.
    @AppStorage("tabLabelsHidden") private var tabLabelsHidden = false
    /// Réglages > Apparence : barre de l'app sur toute la largeur, sinon celle d'iOS.
    @AppStorage("tabBarFull") private var tabBarFull = true
    /// Valeur figée tant que les Réglages sont ouverts (voir `Player.settingsOpen`).
    private var barFullShown: Bool { player.tabBarFullHeld ?? tabBarFull }
    /// Réglages › Apparence, option : la recherche à part, à droite de la barre d'iOS (voir `searchRole`).
    @AppStorage("tabBarSearchApart") private var tabBarSearchApart = false
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
            Tab(value: 1, role: searchRole) {
                TabStack(active: tab == 1, popRequest: searchFocus) { SearchView(focusRequest: searchFocus) }
            } label: {
                tabLabel(tr("Recherche"), Image(systemName: "magnifyingglass"))
            }
        }
        // Réduite en défilant seulement quand le mini-lecteur est là (elle lui fait de la place) : sans titre en cours,
        // la barre restait sinon réduite à l'onglet ouvert, bibliothèque cachée, pour rien.
        .tabBarMinimizeBehavior(player.miniShown ? .onScrollDown : .never)
        .tabViewBottomAccessory(isEnabled: player.miniShown) {
            BarMiniPlayer().environment(player)
        }
    }

    /// Rôle de l'onglet Recherche. Par défaut, sur iOS 27 : simple onglet de recherche, qu'iOS 27 range dans le bloc des
    /// onglets et sort en rond à droite quand la barre se réduit, comme Apple Music. Option « Recherche à part » : Accueil et
    /// Bibliothèque à gauche, la recherche à droite, comme sur iOS 26 ; sur iOS 27, c'est le rôle « mis en avant » qui la
    /// donne. Sur iOS 26, la recherche est toujours à part.
    @available(iOS 26.1, *)
    private var searchRole: TabRole {
        if player.tabBarSearchApartHeld ?? tabBarSearchApart, #available(iOS 27.0, *) { return .prominent }
        return .search
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

    /// Réglages › Téléchargements : la Bibliothèque, puis sa page Téléchargements une fois la feuille des Réglages fermée.
    private func showDownloadsPage() {
        selectOwn(2)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            player.requestedSection = .downloads
        }
    }

    /// Page d'un onglet : gardée en place une fois ouverte, cachée quand un autre onglet est affiché.
    private func ownPage<Page: View>(_ id: Int, _ page: Page) -> some View {
        page
            .opacity(tab == id ? 1 : 0)
            .allowsHitTesting(tab == id)
            .accessibilityHidden(tab != id)
            // Animations arrêtées dans les pages cachées : avant, l'icône du titre en cours y tournait pour rien.
            .environment(\.pageVisible, tab == id)
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
        .background(ScrollCollapse(active: !player.showFullPlayer && player.miniShown,
                                   collapsed: barCollapsed) { barCollapsed = $0 })
        .onChange(of: !player.miniShown) { _, empty in if empty { barCollapsed = false } }
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
                .modifier(GlassCalm(open: player.showFullPlayer))
                // Ici plutôt qu'avec les autres réactions plus bas : ajoutée à cette longue chaîne, elle dépassait ce que le
                // compilateur sait vérifier.
                .onChange(of: player.openDownloadsPage) { showDownloadsPage() }
            // Mini-lecteur posé au-dessus de la barre d'onglets, sous le grand lecteur. Il ignore le clavier :
            // celui-ci le recouvre simplement, sans rien déplacer ni retirer (le baisser en faisant défiler reste fluide).
            if !MiniPlayerMetrics.inTabBar {
                VStack {
                    Spacer()
                    if player.miniShown {
                        MiniPlayer()
                            .padding(.bottom, MiniPlayerMetrics.tabBar)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(.keyboard)
                .accessibilityHidden(player.showFullPlayer)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: !player.miniShown)
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
        // Page MP3 renommée sur ce téléphone, comme les titres aimés.
        .alert(tr("Renommer"), isPresented: Binding(get: { player.renamingMp3 }, set: { player.renamingMp3 = $0 })) {
            TextField("MP3", text: $mp3Name)
            Button(tr("Annuler"), role: .cancel) {}
            Button("OK") { player.setMp3Title(mp3Name) }
        } message: {
            Text(tr("Seulement sur ce téléphone. Laisse vide pour revenir à « %@ ».", "MP3"))
        }
        .onChange(of: player.renamingMp3) { _, open in if open { mp3Name = player.mp3Title } }
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
        // MP3 importés : choix du fichier, fenêtre nom / artiste / pochette, confirmation avant suppression.
        // Lu une fois le sélecteur fermé : la fenêtre nom / artiste / pochette s'ouvre ensuite sans conflit d'affichage.
        .sheet(isPresented: Binding(get: { player.importingMp3 }, set: { player.importingMp3 = $0 }), onDismiss: {
            guard let url = pickedMp3 else { return }
            pickedMp3 = nil
            // La copie faite pour l'app est gardée par la fenêtre d'import (lue à l'envoi), qui la supprime en se fermant.
            Task { await player.importMp3(from: url) }
        }) {
            // Le sélecteur se ferme tout seul et peut annoncer le fichier choisi APRÈS sa fermeture : la fenêtre d'import ne
            // s'ouvrait alors pas (rien de choisi au moment de la fermeture), et le fichier était pris à l'essai suivant.
            // Choisi avant la fermeture : importé à la fermeture ; après : importé tout de suite.
            Mp3FilePicker { url in
                if player.importingMp3 {
                    pickedMp3 = url
                } else {
                    Task { await player.importMp3(from: url) }
                }
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { player.mp3Editor }, set: { player.mp3Editor = $0 })) { edit in
            Mp3EditView(edit: edit).environment(player)
        }
        .confirmationDialog(tr("Supprimer ce MP3 ?"),
                            isPresented: Binding(get: { player.deletingMp3 != nil }, set: { if !$0 { player.deletingMp3 = nil } }),
                            titleVisibility: .visible, presenting: player.deletingMp3) { track in
            Button(tr("Supprimer"), role: .destructive) { Task { await player.deleteMp3(track) } }
        } message: { track in
            Text(tr("« %@ » sera supprimé de ton compte Deezer (téléphone, ordinateur, site), et retiré de tes titres aimés et de tes playlists. Cette action est définitive.", track.title))
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
    /// Largeur à l'écran de la première page de la pile, et de la pile elle-même (voir la reconstruction plus bas).
    @State private var rootWidth: CGFloat = 0
    @State private var stackWidth: CGFloat = 0
    /// Change : la pile est reconstruite.
    @State private var rebuilds = 0

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .miniPlayerSpace()
                .background(EdgeOnlyBack())
                .pageBackground()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).width } action: { rootWidth = $0 }
                .navigationDestination(for: Route.self) { DetailView(route: $0).miniPlayerSpace().pageBackground() }
                .navigationDestination(for: LibrarySection.self) { LibrarySectionView(section: $0).miniPlayerSpace().pageBackground() }
        }
        .id(rebuilds)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).width } action: { stackWidth = $0 }
        // iOS 27.0.1, barre de l'app, lancement déjà connecté : la pile posait sa première page à une largeur fausse
        // (174 points au lieu de 402) et ne la recalculait jamais. L'accueil restait tout noir, seule la barre d'onglets
        // visible. iOS 27.2 la corrige seul en un instant : la pile n'est reconstruite que si l'écart dure (0,6 s), deux
        // fois au plus. Rien d'autre à faire quand les largeurs sont égales. Relancé aussi après chaque reconstruction :
        // avant, la page retombée sur la même largeur fausse n'avait jamais son second essai.
        .task(id: "\(rootWidth - stackWidth)|\(rebuilds)") {
            guard abs(rootWidth - stackWidth) > 1, rootWidth > 0, stackWidth > 0, path.isEmpty, rebuilds < 2 else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            rebuilds += 1
        }
        .environment(\.openRoute) { path.append($0) }
        // Page demandée depuis le lecteur plein écran : ouverte dans l'onglet affiché.
        .onChange(of: player.requestedRoute) { _, route in
            guard active, let route else { return }
            path.append(route)
            player.requestedRoute = nil
        }
        .onChange(of: player.requestedSection) { _, section in
            guard active, let section else { return }
            path.append(section)
            player.requestedSection = nil
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
        let mini = player.miniShown
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if MiniPlayerMetrics.inTabBar {
                // Barre de l'app : la place est à laisser ici. Barre d'iOS : c'est elle qui s'en charge.
                if player.tabBarFullHeld ?? tabBarFull { Color.clear.frame(height: GlassBarMetrics.pageSpace(mini: mini)) }
            } else if mini {
                Color.clear.frame(height: MiniPlayerMetrics.mini)
            }
        }
    }
}

extension View {
    func miniPlayerSpace() -> some View { modifier(MiniPlayerSpace()) }
}

/// Verre des pages « au repos » (sans réaction au doigt) pendant que le grand lecteur est ouvert, mais seulement une fois
/// son animation d'ouverture finie. Avant, le verre de toutes les pages était reconfiguré dès la première image de
/// l'animation (à-coup à l'ouverture). Les appuis sur les pages sont déjà bloqués dès l'ouverture (`allowsHitTesting`).
private struct GlassCalm: ViewModifier {
    let open: Bool
    @State private var calm = false

    func body(content: Content) -> some View {
        content
            .environment(\.glassReactsToTouch, !calm)
            .task(id: open) {
                guard open else { calm = false; return }
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { calm = true }
            }
    }
}
