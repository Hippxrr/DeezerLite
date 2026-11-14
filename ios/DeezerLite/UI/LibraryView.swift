import SwiftUI

/// Rubriques de la Bibliothèque qui ouvrent leur propre page (les playlists sont directement sur la page d'accueil).
enum LibrarySection: Hashable, CaseIterable {
    case albums, artists, downloads, stats

    var title: String {
        switch self {
        case .albums: tr("Albums")
        case .artists: tr("Artistes")
        case .downloads: tr("Téléchargés")
        case .stats: tr("Stats")
        }
    }

    var icon: String {
        switch self {
        case .albums: "square.stack.fill"
        case .artists: "music.mic"
        case .downloads: "arrow.down.circle.fill"
        case .stats: "chart.bar.fill"
        }
    }
}

/// Bibliothèque : quatre rubriques en tuiles, puis les playlists, directement visibles.
struct LibraryView: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @State private var creating = false
    @State private var newName = ""

    /// Ce qui est déjà sur l'accueil (titres aimés, éléments épinglés) n'est pas répété ici.
    private var playlists: [Card]? {
        player.library[0].map { list in list.filter { $0.kind != "loved" && !player.isPinned($0) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                sections
                HStack {
                    Text(tr("Playlists")).font(.title3.bold())
                    Spacer()
                    Button { newName = ""; creating = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .surface(Circle())
                            .frame(width: 44, height: 44) // zone d'appui de 44 pt, cercle inchangé
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(tr("Nouvelle playlist"))
                }
                playlistRows
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await player.loadLibrary(0, force: true)
            await player.refreshLoved()
        }
        // Relancé aussi au changement de profil.
        .task(id: player.profileEpoch) { await player.loadLibrary(0, force: false) }
        .newPlaylistPrompt(isPresented: $creating, name: $newName) { title in
            Task { await player.createPlaylist(title) }
        }
    }

    private var header: some View {
        PageTitleBar(title: tr("Bibliothèque"))
    }

    private var sections: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                NavigationLink(value: section) {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        Text(section.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 58)
                    .surface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private var playlistRows: some View {
        LazyVStack(spacing: 10) {
            // Flow et Titres aimés retirés de l'accueil : ils sont ici, en tête des playlists.
            if !player.flowOnHome {
                Button { player.playFlow() } label: {
                    ItemRow(title: "Flow", subtitle: "", trailing: "play.fill") { FlowArt() }
                }
                .buttonStyle(.pressable)
                .contextMenu {
                    Button { withAnimation { player.setFlowOnHome(true) } } label: { Label(tr("Afficher sur l'accueil"), systemImage: "house") }
                    CoverMenu(card: Player.flowCard)
                }
            }
            if !player.lovedOnHome {
                Button { openRoute(.loved) } label: {
                    ItemRow(title: player.lovedTitle, subtitle: player.lovedIds.count == 1 ? tr("1 titre") : tr("%@ titres", "\(player.lovedIds.count)")) {
                        if let url = player.lovedCover {
                            CoverView(url: url, side: 64, radius: 10)
                        } else {
                            LovedArt(side: 64, radius: 10)
                        }
                    }
                }
                .buttonStyle(.pressable)
                .contextMenu {
                    DownloadCollectionMenu(card: player.lovedMenuCard)
                    Button { withAnimation { player.setLovedOnHome(true) } } label: { Label(tr("Afficher sur l'accueil"), systemImage: "house") }
                    RenameLovedMenu()
                    CoverMenu(card: player.lovedMenuCard)
                }
            }
            if let playlists {
                ForEach(playlists.indices, id: \.self) { i in CardRow(card: playlists[i]) }
                if playlists.isEmpty && player.flowOnHome && player.lovedOnHome {
                    Text(tr("Pas d'autre playlist.")).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card).frame(height: 84)
                }
            }
        }
    }
}

/// Page d'une rubrique de la Bibliothèque.
struct LibrarySectionView: View {
    @Environment(Player.self) private var player
    let section: LibrarySection
    /// « Tirer pour actualiser » sur les Stats.
    @State private var statsRefresh = 0

    /// Numéro de la liste chez `Player` (albums, artistes) ; les autres rubriques ont leurs propres données.
    private var list: Int? {
        switch section {
        case .albums: 1
        case .artists: 2
        case .downloads, .stats: nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch section {
                case .downloads: DownloadsView()
                case .stats: MonthView(refresh: statsRefresh)
                case .albums, .artists: rows
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            if section == .stats { statsRefresh += 1 }
            if let list { await player.loadLibrary(list, force: true) }
        }
        .task(id: player.profileEpoch) {
            if let list { await player.loadLibrary(list, force: false) }
        }
    }

    @ViewBuilder
    private var rows: some View {
        LazyVStack(spacing: 10) {
            if let list, let cards = player.library[list]?.filter({ !player.isPinned($0) }) {
                ForEach(cards.indices, id: \.self) { i in CardRow(card: cards[i]) }
                if cards.isEmpty {
                    Text(section == .albums ? tr("Aucun album dans ta bibliothèque.") : tr("Aucun artiste suivi."))
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card).frame(height: 84)
                }
            }
        }
    }
}

/// Réglages : simples, dans le style de l'app (titres de section, cartes sombres, couleur du thème).
struct SettingsView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false
    /// Place prise par les pochettes enregistrées (relue à l'ouverture des Réglages et après effacement).
    @State private var coverBytes = 0
    @State private var confirmClearCovers = false
    /// Onglet affiché (gardé d'une ouverture à l'autre).
    @AppStorage("settingsTab") private var tab = SettingsTab.general
    /// Onglets du bas sans leur nom (voir `MainTabs`).
    @AppStorage("tabLabelsHidden") private var tabLabelsHidden = false
    @AppStorage("tabBarFull") private var tabBarFull = true
    @AppStorage("miniProgress") private var miniProgress = true
    @AppStorage("fullBleedCover") private var fullBleedCover = false

    enum SettingsTab: String, CaseIterable {
        case general, look, sound, quality
        var title: String {
            switch self {
            case .general: tr("Général")
            case .look: tr("Apparence")
            case .sound: tr("Son")
            case .quality: tr("Qualité")
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .general: general
                    case .look: look
                    case .sound: sound
                    case .quality: quality
                    }
                    Text("Deezer Lite \(version)").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
                .padding(16)
                .animation(nil, value: tab)
            }
            // Onglets fixés en haut : on change de rubrique sans faire défiler.
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker(tr("Rubrique"), selection: $tab) {
                    ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Fond opaque : sans lui, le texte qui défile passait sous la barre et s'y mêlait.
                .background(.ultraThickMaterial)
            }
            .sensoryFeedback(.selection, trigger: tab)
            .sheetBackground(Theme.accent, strength: 0.3)
            .navigationTitle(tr("Réglages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() }.fontWeight(.semibold) }
            }
            .confirmationDialog(tr("Se déconnecter de Deezer ?"), isPresented: $confirmLogout, titleVisibility: .visible) {
                Button(tr("Se déconnecter"), role: .destructive) {
                    dismiss()
                    Task { await player.logout() }
                }
            } message: {
                Text(tr("Session, historique, éléments épinglés, téléchargements, pochettes perso et nom des titres aimés sont effacés du téléphone."))
            }
        }
        // Réglages ouverts : « Qui écoute ? » s'affiche ici, par-dessus eux (voir `Player.settingsOpen`).
        .sheet(isPresented: Binding(get: { player.choosingProfile && player.settingsOpen }, set: { player.choosingProfile = $0 }), onDismiss: { player.keepCurrentProfile() }) {
            ProfilePicker().environment(player).presentationDetents([.medium, .large])
        }
        .onAppear { player.settingsOpen = true }
        .onDisappear { player.settingsOpen = false }
        .tint(Theme.accent)
    }

    /// Accueil, lecture, stockage, compte.
    @ViewBuilder
    private var general: some View {
        languageGroup
        group(tr("Accueil")) {
            NavigationLink { RecoSettingsView() } label: {
                row("square.grid.2x2", tr("Personnaliser l'accueil")) { chevron }
            }
            .buttonStyle(.plain)
        }
        lecture
        account
    }

    /// Langue de l'app : changée tout de suite, sans relancer.
    private var languageGroup: some View {
        group(tr("Langue")) {
            Picker(tr("Langue"), selection: Binding(get: { LanguageStore.shared.current }, set: { LanguageStore.shared.select($0) })) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)
        }
    }

    /// Couleur du fond de l'app, en mode sombre.
    @ViewBuilder
    private var backgroundGroup: some View {
        group(tr("Fond")) {
            HStack(spacing: 10) {
                ForEach(AppBackground.allCases) { b in backgroundChoice(b) }
            }
            .padding(14)
        }
        Text(tr("Le fond s'applique en mode sombre. Le grand lecteur garde le fond de la pochette."))
            .font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
    }

    private func backgroundChoice(_ b: AppBackground) -> some View {
        let selected = ThemeStore.shared.background == b
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { ThemeStore.shared.setBackground(b) }
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(b.color)
                    .frame(height: 44)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selected ? Theme.accent : Color.primary.opacity(0.18), lineWidth: selected ? 2 : 1)
                    }
                Text(tr(b.name)).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Thème, icône.
    @ViewBuilder
    private var look: some View {
        group(tr("Mode")) {
            Picker(tr("Mode"), selection: Binding(get: { ThemeStore.shared.appearance }, set: { ThemeStore.shared.setAppearance($0) })) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)
        }
        Text(tr("Système : clair ou sombre comme l'iPhone. Le grand lecteur reste toujours sombre."))
            .font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
        backgroundGroup
        group(tr("Apparence")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "paintpalette").foregroundStyle(Theme.accent).frame(width: 26)
                    Text(tr("Thème"))
                    Spacer()
                    Text(tr(ThemeStore.shared.palette.name)).foregroundStyle(.secondary)
                }
                ThemeDots()
            }
            .padding(14)
            divider
            HStack(spacing: 12) {
                Image(systemName: "app").foregroundStyle(Theme.accent).frame(width: 26)
                Text(tr("Icône"))
                Spacer()
                AppIconPicker()
            }
            .padding(14)
            divider
            Toggle(isOn: $tabLabelsHidden) {
                HStack(spacing: 12) {
                    Image(systemName: "textformat").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Masquer le nom des onglets"))
                        Text(tr("Icônes seules dans la barre du bas")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(14)
            divider
            Toggle(isOn: $miniProgress) {
                HStack(spacing: 12) {
                    Image(systemName: "minus").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Barre de progression du mini-lecteur"))
                        Text(tr("Fine barre en bas du mini-lecteur")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(14)
            divider
            Toggle(isOn: $fullBleedCover) {
                HStack(spacing: 12) {
                    Image(systemName: "photo").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Pochette pleine largeur"))
                        Text(tr("Grand lecteur : la pochette en haut, sur toute la largeur, fondue dans le fond")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(14)
            if MiniPlayerMetrics.inTabBar {
                divider
                Toggle(isOn: $tabBarFull) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.bottomthird.inset.filled").foregroundStyle(Theme.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Barre d'onglets complète"))
                            Text(tr("Toute la largeur, la recherche passe à droite quand la barre se réduit. Désactivée : la barre d'iOS")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(Theme.accent)
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var lecture: some View {
        group(tr("Lecture")) {
            Toggle(isOn: Binding(get: { player.resumeOnLaunch }, set: { player.setResumeOnLaunch($0) })) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Reprendre la dernière écoute"))
                        Text(tr("Au relancement de l'app : même titre, même position")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(14)
            divider
            Toggle(isOn: Binding(get: { player.geniusLyrics }, set: { player.setGeniusLyrics($0) })) {
                HStack(spacing: 12) {
                    Image(systemName: "quote.bubble").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Paroles de secours (Genius)"))
                        Text(tr("Si Deezer n'a pas les paroles : texte simple, en ligne. Genius reçoit alors le titre et l'artiste.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(Theme.accent)
            .padding(14)
        }
    }

    /// Fondu enchaîné, égaliseur.
    @ViewBuilder
    private var sound: some View {
        group(tr("Enchaînement")) {
            Stepper(value: Binding(get: { player.crossfade }, set: { player.setCrossfade($0) }), in: 0...10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Fondu enchaîné"))
                        Text(player.crossfade == 0 ? tr("Désactivé : les titres s'enchaînent sans blanc") : tr("%@ s : la fin d'un titre se mêle au début du suivant", "\(player.crossfade)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        group(tr("Égaliseur")) { EqualizerPanel() }
        Text(tr("Fréquences en Hz. Toucher un curseur crée ton réglage « Personnalisé »."))
            .font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
    }

    /// Qualité en Wi-Fi, en données mobiles, des téléchargements.
    @ViewBuilder
    private var quality: some View {
        group(tr("Qualité en Wi-Fi")) { qualityRows(player.quality) { player.setQuality($0) } }
        group(tr("Qualité en données mobiles")) { qualityRows(player.cellularQuality) { player.setCellularQuality($0) } }
        group(tr("Qualité des téléchargements")) { qualityRows(player.downloadQuality) { player.setDownloadQuality($0) } }
        Text(tr("Pour les nouveaux téléchargements, en Wi-Fi et en 4G/5G.")).font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
        if let playing = player.current?.quality {
            Text(tr("Titre en cours : %@", playing)).font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
        }
    }

    @ViewBuilder
    private var account: some View {
        // Compte Deezer : le profil ouvert ; compte Famille : on peut en changer.
        if let me = player.currentProfile {
            group(tr("Compte Deezer")) {
                if player.isFamily {
                    NavigationLink { ProfilePage().environment(player) } label: { profileRow(me, detail: tr("Compte Famille · %@ profils", "\(player.profiles.count)")) { chevron } }
                        .buttonStyle(.plain)
                } else {
                    profileRow(me, detail: tr("Compte personnel")) { EmptyView() }
                }
            }
        }

        // Historique officiel : pour voir que les écoutes sont bien comptées par Deezer.
        group(tr("Statistiques")) {
            NavigationLink { RecentListensPage().environment(player) } label: {
                row("clock.arrow.circlepath", tr("Dernières écoutes")) { chevron }
            }
            .buttonStyle(.plain)
        }

        group(tr("Stockage")) {
            Button { confirmClearCovers = true } label: {
                row("photo", tr("Effacer les pochettes enregistrées")) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(coverBytes), countStyle: .file)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .task { coverBytes = CoverLoader.shared.diskUsage }
            .confirmationDialog(tr("Effacer les pochettes enregistrées ?"), isPresented: $confirmClearCovers, titleVisibility: .visible) {
                Button(tr("Effacer"), role: .destructive) {
                    CoverLoader.shared.clear()
                    coverBytes = CoverLoader.shared.diskUsage
                    player.showToast(tr("Pochettes effacées"))
                }
                Button(tr("Annuler"), role: .cancel) {}
            } message: {
                Text(tr("Seules les pochettes gardées pour un affichage rapide sont effacées. Elles sont retéléchargées quand elles réapparaissent à l'écran. Tes téléchargements, ta session, ton historique et tes réglages ne sont pas touchés."))
            }
            divider
            // Ce qui prend vraiment de la place : les téléchargements. Leur taille, et leur page pour en supprimer.
            NavigationLink { LibrarySectionView(section: .downloads).environment(player) } label: {
                row("arrow.down.circle", tr("Téléchargements")) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(player.downloadBytes), countStyle: .file)).foregroundStyle(.secondary)
                    chevron
                }
            }
            .buttonStyle(.plain)
        }

        group(nil) {
            Button { confirmLogout = true } label: {
                Text(tr("Se déconnecter")).foregroundStyle(.red).frame(maxWidth: .infinity).padding(14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Section : petit titre, puis une carte qui regroupe ses lignes.
    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(spacing: 0) { content() }
                .surface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
        }
    }

    private func row<Trailing: View>(_ icon: String, _ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            Text(title)
            Spacer()
            trailing()
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private func profileRow<Trailing: View>(_ p: Profile, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: p, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private var divider: some View {
        Divider().padding(.leading, 52)
    }

    private func qualityRows(_ selected: AudioQuality, choose: @escaping (AudioQuality) -> Void) -> some View {
        let all: [AudioQuality] = [.flac, .mp3High, .mp3Low]
        return ForEach(all.indices, id: \.self) { i in
            let q = all[i]
            if i > 0 { divider }
            Button { choose(q) } label: {
                HStack(spacing: 12) {
                    Image(systemName: q.icon).foregroundStyle(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.title)
                        Text(q.rate).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if q == selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.accent) }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Six pastilles de couleur ; la choisie est entourée.
private struct ThemeDots: View {
    var body: some View {
        let current = ThemeStore.shared.palette.id
        // Six par ligne : tous les thèmes restent visibles sans défiler.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6), spacing: 6) {
            ForEach(Theme.palettes) { p in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { ThemeStore.shared.select(p.id) }
                } label: {
                    Circle()
                        .fill(p.accent)
                        .frame(width: 28, height: 28)
                        .padding(4)
                        .overlay { Circle().strokeBorder(p.id == current ? p.accent : .clear, lineWidth: 2) }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(p.name))
            }
        }
        .sensoryFeedback(.selection, trigger: current)
    }
}

/// Ligne de réglage : icône sur pastille de couleur (comme les Réglages d'iOS), titre et détail.
struct SettingLabel: View {
    let title: String
    let icon: String
    let color: Color
    let detail: String?

    init(_ title: String, icon: String, color: Color, detail: String?) {
        self.title = title
        self.icon = icon
        self.color = color
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

extension AudioQuality {
    var title: String {
        switch self {
        case .flac: "FLAC"
        case .mp3High: tr("MP3 haute qualité")
        case .mp3Low: tr("MP3 économique")
        }
    }

    var detail: String {
        switch self {
        case .flac: tr("Sans perte · environ 1 000 kbit/s")
        case .mp3High: "320 kbit/s"
        case .mp3Low: tr("128 kbit/s · moins de données mobiles")
        }
    }

    var icon: String {
        switch self {
        case .flac: "waveform"
        case .mp3High: "music.note"
        case .mp3Low: "antenna.radiowaves.left.and.right"
        }
    }

    var shortTitle: String {
        switch self {
        case .flac: "FLAC"
        case .mp3High: "MP3 HQ"
        case .mp3Low: tr("MP3 éco")
        }
    }

    var rate: String {
        switch self {
        case .flac: tr("Sans perte")
        case .mp3High: "320 kbit/s"
        case .mp3Low: "128 kbit/s"
        }
    }

    var color: Color {
        switch self {
        case .flac: Theme.accent
        case .mp3High: .orange
        case .mp3Low: .green
        }
    }
}

/// Recommandations de l'accueil : activer, choisir et ordonner les catégories (comme sur la version bureau).
struct RecoSettingsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { player.flowOnHome }, set: { player.setFlowOnHome($0) })) {
                    SettingLabel(tr("Flow sur l'accueil"), icon: "waveform", color: Theme.accent, detail: nil)
                }
                Toggle(isOn: Binding(get: { player.lovedOnHome }, set: { player.setLovedOnHome($0) })) {
                    SettingLabel(tr("%@ sur l'accueil", player.lovedTitle), icon: "heart.fill", color: .pink, detail: nil)
                }
            } footer: {
                Text(tr("Désactivés, ils se trouvent en tête de tes playlists dans la Bibliothèque. Sur l'accueil, appui long puis « Réorganiser l'accueil » pour changer leur ordre."))
            }
            Section {
                Toggle(isOn: Binding(
                    get: { player.reco.enabled },
                    set: { on in player.updateReco { r in
                        r.enabled = on
                        if on && r.order.allSatisfy(r.hidden.contains) { r.hidden = RecoPrefs().hidden } // tout était masqué : on revient aux catégories de base
                    } }
                )) {
                    SettingLabel(tr("Recommandations"), icon: "sparkles", color: .pink, detail: nil)
                }
            } footer: {
                Text(tr("Désactivées, l'accueil ne contacte plus Deezer pour ses suggestions."))
            }
            if player.reco.enabled {
                Section {
                    ForEach(player.reco.order, id: \.self) { kind in
                        Toggle(RecoPrefs.label(kind), isOn: Binding(
                            get: { !player.reco.hidden.contains(kind) },
                            set: { on in player.updateReco { r in
                                if on { r.hidden.removeAll { $0 == kind } } else if !r.hidden.contains(kind) { r.hidden.append(kind) }
                            } }
                        ))
                    }
                    .onMove { from, to in player.updateReco { $0.order.move(fromOffsets: from, toOffset: to) } }
                } header: {
                    Text(tr("Catégories"))
                } footer: {
                    Text(tr("Fais glisser pour changer l'ordre sur l'accueil. Appui long sur le titre d'une rangée de l'accueil pour la masquer."))
                }
                Section {
                    Stepper(value: Binding(
                        get: { player.reco.curatedMax },
                        set: { n in player.updateReco { $0.curatedMax = n } }
                    ), in: 0...12) {
                        LabeledContent(tr("Sélections de la rédaction"), value: "\(player.reco.curatedMax)")
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .listRowBackground(Theme.card)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(tr("Personnaliser l'accueil"))
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// Icône de l'app : violette (par défaut) ou blanche. iOS affiche lui-même une confirmation au changement.
private struct AppIconPicker: View {
    @State private var selected = UIApplication.shared.alternateIconName

    private let choices: [(name: String?, preview: String, label: String)] = [
        (nil, "IconPreview", tr("Violette")),
        ("AppIcon-White", "IconPreviewWhite", "Blanche"),
        ("AppIcon-BlackViolet", "IconPreviewBlackViolet", "Noire, cœur violet"),
        ("AppIcon-BlackWhite", "IconPreviewBlackWhite", "Noire, cœur blanc"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices, id: \.preview) { choice in
                let on = selected == choice.name
                Button {
                    guard !on else { return }
                    Task {
                        do {
                            try await UIApplication.shared.setAlternateIconName(choice.name)
                            selected = choice.name
                        } catch {
                            Player.shared.showToast(tr("Impossible de changer l'icône"))
                        }
                    }
                } label: {
                    Image(choice.preview)
                        .resizable()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(on ? Theme.accent : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Icône %@", tr(choice.label).lowercased()))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}
