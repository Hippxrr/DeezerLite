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
    /// Page des MP3 importés (même route à l'ouverture et pour leur nombre gardé en mémoire).
    static let mp3Route = Route.detail(kind: "mp3", id: 0, title: "MP3")
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @State private var creating = false
    @State private var newName = ""
    @State private var reordering = false
    /// « 12 titres · 47 min » des MP3, et le numéro des changements de MP3 pour lequel il a été lu. Gardé ici : la copie
    /// des pages du lecteur n'est pas suivie par l'écran, la ligne restait vide après la lecture.
    @State private var mp3Summary: String?
    @State private var mp3SummaryRevision = -1

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
        let rows = libraryRows(player)
        return LazyVStack(spacing: 10) {
            // Appui long puis « Réorganiser les playlists » pour changer l'ordre (comme sur l'accueil).
            ForEach(rows) { row in self.row(row, canReorder: rows.count > 1) }
            if let playlists {
                if playlists.isEmpty && player.flowOnHome && player.lovedOnHome {
                    Text(tr("Pas d'autre playlist.")).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                }
            } else if player.loadFailed.contains("library0") {
                RetryNote { await player.loadLibrary(0, force: true) }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card).frame(height: 84)
                }
            }
        }
        .glassGroup()
        .animation(.snappy(duration: 0.3), value: rows.map(\.id))
        .sheet(isPresented: $reordering) {
            LibraryOrderView().environment(player).presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func reorderButton(_ canReorder: Bool) -> some View {
        if canReorder {
            Button { reordering = true } label: { Label(tr("Réorganiser les playlists"), systemImage: "arrow.up.arrow.down") }
        }
    }

    @ViewBuilder
    private func row(_ row: LibraryRow, canReorder: Bool) -> some View {
        switch row {
        case .flow:
            // Flow et Titres aimés retirés de l'accueil : ils sont ici, parmi les playlists.
            Button { player.tapFlow() } label: {
                ItemRow(title: "Flow", subtitle: "", trailing: "play.fill") { FlowArt() }
            }
            .buttonStyle(.pressable)
            .contextMenu {
                Button { withAnimation { player.setFlowOnHome(true) } } label: { Label(tr("Afficher sur l'accueil"), systemImage: "house") }
                CoverMenu(card: Player.flowCard)
                reorderButton(canReorder)
            }
        case .loved:
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
                reorderButton(canReorder)
            }
        case .mp3:
            // MP3 importés sur le compte : la page permet d'en importer, de les modifier et de les supprimer. Nom et pochette
            // changeables sur ce téléphone, comme les titres aimés.
            Button { openRoute(Self.mp3Route) } label: {
                ItemRow(title: player.mp3Title, subtitle: mp3Summary ?? "") {
                    CardArt(card: player.mp3MenuCard)
                }
            }
            // Nombre de MP3 : la copie en mémoire si elle existe, sinon lue une fois, puis relue seulement après un import,
            // une modification ou une suppression.
            .task(id: player.mp3Revision) {
                if mp3Summary == nil, let d = player.cachedDetail(Self.mp3Route) { mp3Summary = DetailView.trackCount(d.tracks.count) }
                guard mp3Summary == nil || mp3SummaryRevision != player.mp3Revision else { return }
                let revision = player.mp3Revision
                if let d = await player.detail(Self.mp3Route, force: false) {
                    mp3Summary = DetailView.trackCount(d.tracks.count)
                    mp3SummaryRevision = revision
                }
            }
            .buttonStyle(.pressable)
            .contextMenu {
                PinMenu(card: player.mp3MenuCard)
                Button { player.renamingMp3 = true } label: { Label(tr("Renommer…"), systemImage: "pencil") }
                CoverMenu(card: player.mp3MenuCard)
                reorderButton(canReorder)
            }
        case .playlist(let card):
            CardRow(card: card, onReorder: canReorder ? { reordering = true } : nil, reorderLabel: tr("Réorganiser les playlists"))
        }
    }
}

/// Une ligne de la liste des playlists de la Bibliothèque.
enum LibraryRow: Identifiable {
    case flow, loved, mp3
    case playlist(Card)

    var id: String {
        switch self {
        case .flow: "flow"
        case .loved: "loved"
        case .mp3: "mp3"
        case .playlist(let card): "playlist-\(card.id)"
        }
    }
}

/// Lignes de la Bibliothèque dans l'ordre choisi : Flow et Titres aimés s'ils ne sont pas sur l'accueil, la page MP3,
/// puis les playlists (sans celles épinglées sur l'accueil). Celles jamais déplacées (nouvelles playlists) en tête.
@MainActor
func libraryRows(_ player: Player) -> [LibraryRow] {
    var all: [LibraryRow] = []
    if !player.flowOnHome { all.append(.flow) }
    if !player.lovedOnHome { all.append(.loved) }
    if !player.isPinned(player.mp3MenuCard) { all.append(.mp3) }
    all += (player.library[0] ?? []).filter { $0.kind != "loved" && !player.isPinned($0) }.map { .playlist($0) }
    let rank = Dictionary(player.libraryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return all.enumerated()
        .sorted { (rank[$0.element.id] ?? $0.offset - 10_000) < (rank[$1.element.id] ?? $1.offset - 10_000) }
        .map(\.element)
}

/// Ordre des playlists de la Bibliothèque : une liste avec des poignées, comme « Réorganiser l'accueil ».
private struct LibraryOrderView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = libraryRows(player)
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            art(row)
                            Text(title(row)).lineLimit(1)
                        }
                    }
                    .onMove { from, to in
                        var ids = rows.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        player.setLibraryOrder(ids)
                    }
                } footer: {
                    Text(tr("Fais glisser avec les poignées à droite."))
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .sheetBackground(Theme.accent, strength: 0.3)
            .navigationTitle(tr("Réorganiser les playlists"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() }.fontWeight(.semibold) }
            }
            .sensoryFeedback(.selection, trigger: rows.map(\.id))
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func art(_ row: LibraryRow) -> some View {
        switch row {
        case .flow: FlowArt(side: 40)
        case .loved:
            if let url = player.lovedCover { CoverView(url: url, side: 40, radius: 8) } else { LovedArt(side: 40, radius: 8) }
        case .mp3: CardArt(card: player.mp3MenuCard, side: 40)
        case .playlist(let card): CardArt(card: card, side: 40)
        }
    }

    private func title(_ row: LibraryRow) -> String {
        switch row {
        case .flow: "Flow"
        case .loved: player.lovedTitle
        case .mp3: player.mp3Title
        case .playlist(let card): card.title
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
        Group {
            if section == .downloads {
                // Sa propre liste (titres téléchargés dans une liste d'iOS, voir `DownloadsView`).
                DownloadsView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if section == .stats { MonthView(refresh: statsRefresh) } else { rows }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .refreshable {
                    if section == .stats { statsRefresh += 1 }
                    if let list { await player.loadLibrary(list, force: true) }
                }
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.large)
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
            } else if let list, player.loadFailed.contains("library\(list)") {
                RetryNote { await player.loadLibrary(list, force: true) }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card).frame(height: 84)
                }
            }
        }
        .glassGroup()
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
    @AppStorage("tabBarSearchApart") private var tabBarSearchApart = false
    /// iOS 27 ou plus (« Recherche à part » n'a d'effet qu'à partir de là).
    private static var iOS27: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    @AppStorage("miniProgress") private var miniProgress = true
    @AppStorage("fullBleedCover") private var fullBleedCover = false
    @AppStorage(BleedShape.key) private var bleedShape = BleedShape.saved
    @AppStorage("saveCoverOnLongPress") private var saveCoverOnLongPress = false
    @AppStorage("downloadCheckGreen") private var downloadCheckGreen = false
    @AppStorage("queueHistory") private var queueHistory = true
    @AppStorage(BackgroundDownloadManager.wifiOnlyKey) private var downloadsWifiOnly = false
    /// Titres téléchargés dans une autre qualité que celle des téléchargements (« Mettre à jour »).
    @State private var qualityChanges: [QualityChange] = []
    @State private var confirmQualityUpdate = false

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
        .toastOverlay() // messages visibles aussi Réglages ouverts
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

    /// Mode et fond, thème et icône, puis les réglages rangés par endroit de l'app (barre d'onglets, grand lecteur,
    /// mini-lecteur, téléchargements). Avant, tous les interrupteurs à la suite dans un seul bloc, chacun avec une phrase.
    @ViewBuilder
    private var look: some View {
        group(tr("Mode")) {
            Picker(tr("Mode"), selection: Binding(get: { ThemeStore.shared.appearance }, set: { ThemeStore.shared.setAppearance($0) })) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)
        }
        backgroundGroup
        group(tr("Thème et icône")) {
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
        }
        group(tr("Barre d'onglets")) {
            toggle("textformat", tr("Masquer le nom des onglets"), $tabLabelsHidden)
            // Barre d'iOS, sur iOS 27 : avant, la recherche y est toujours à part.
            if MiniPlayerMetrics.inTabBar, Self.iOS27 {
                divider
                toggle("magnifyingglass.circle", tr("Recherche à part"), $tabBarSearchApart)
            }
        }
        group(tr("Grand lecteur")) {
            toggle("photo", tr("Pochette pleine largeur"), $fullBleedCover)
            // Hauteur de la pochette pleine largeur : entière (carrée, prolongée par son reflet), moyenne (avec le fond d'entière
            // ou celui de haute), ou haute jusqu'au titre. Avant, un interrupteur « Pochette haute » : entière ou haute seulement.
            if fullBleedCover {
                divider
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.portrait").foregroundStyle(Theme.accent).frame(width: 26)
                        Text(tr("Hauteur de la pochette"))
                    }
                    Picker(tr("Hauteur de la pochette"), selection: $bleedShape) {
                        ForEach(BleedShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
            }
            divider
            toggle("square.and.arrow.down", tr("Appui long : enregistrer la pochette"), $saveCoverOnLongPress)
            divider
            toggle("clock.arrow.circlepath", tr("Historique dans la file"), $queueHistory)
        }
        group(tr("Mini-lecteur")) {
            toggle("minus", tr("Barre de progression"), $miniProgress)
        }
        group(tr("Téléchargements")) {
            toggle("checkmark.circle.fill", tr("Coche verte"), $downloadCheckGreen,
                   iconColor: downloadCheckGreen ? Theme.downloadGreen : Theme.accent)
        }
    }

    @ViewBuilder
    private var lecture: some View {
        group(tr("Lecture")) {
            toggle("clock.arrow.circlepath", tr("Reprendre la dernière écoute"),
                   Binding(get: { player.resumeOnLaunch }, set: { player.setResumeOnLaunch($0) }))
            divider
            // Seule précision gardée : ce que Genius reçoit (un autre service que Deezer).
            toggle("quote.bubble", tr("Paroles de secours (Genius)"),
                   Binding(get: { player.geniusLyrics }, set: { player.setGeniusLyrics($0) }),
                   detail: tr("Genius reçoit le titre et l'artiste"))
        }
    }

    /// Fondu enchaîné, égaliseur.
    @ViewBuilder
    private var sound: some View {
        group(tr("Enchaînement")) {
            Stepper(value: Binding(get: { player.crossfade }, set: { player.setCrossfade($0) }), in: 0...10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.accent).frame(width: 26)
                    Text(tr("Fondu enchaîné"))
                    Spacer()
                    Text(player.crossfade == 0 ? tr("Désactivé") : "\(player.crossfade) s").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            divider
            toggle("speaker.wave.2", tr("Volume égal entre les titres"),
                   Binding(get: { player.normalizeVolume }, set: { player.setNormalizeVolume($0) }))
        }
        group(tr("Égaliseur")) { EqualizerPanel() }
    }

    /// Qualité en Wi-Fi, en données mobiles, des téléchargements.
    @ViewBuilder
    private var quality: some View {
        group(tr("Qualité en Wi-Fi")) { qualityRows(player.quality) { player.setQuality($0) } }
        group(tr("Qualité en données mobiles")) { qualityRows(player.cellularQuality) { player.setCellularQuality($0) } }
        group(tr("Qualité des téléchargements")) { qualityRows(player.downloadQuality) { player.setDownloadQuality($0) } }
            // Recalculé à chaque changement de qualité, hors du fil principal.
            .task(id: player.downloadQuality) { qualityChanges = await player.downloadsInOtherQuality() }
        if !qualityChanges.isEmpty { qualityUpdateRow }
        if let playing = player.current?.quality {
            Text(tr("Titre en cours : %@", playing)).font(.caption).foregroundStyle(.secondary).padding(.top, -14).padding(.leading, 4)
        }
        group(tr("Téléchargements")) {
            toggle("wifi", tr("Télécharger en Wi-Fi seulement"), $downloadsWifiOnly)
                .onChange(of: downloadsWifiOnly) { BackgroundDownloadManager.shared.wifiOnlyChanged() }
        }
    }

    /// Titres déjà téléchargés dans une autre qualité : les retélécharger dans celle choisie, après confirmation.
    private var qualityUpdateRow: some View {
        Button { confirmQualityUpdate = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Mettre à jour les titres téléchargés"))
                    Text(tr("%@ titres dans une autre qualité", "\(qualityChanges.count)")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
        .confirmationDialog(tr("Mettre à jour la qualité ?"), isPresented: $confirmQualityUpdate, titleVisibility: .visible) {
            Button(tr("Mettre à jour")) {
                player.updateDownloadQuality(qualityChanges)
                qualityChanges = []
            }
        } message: {
            Text(qualityUpdateSummary)
        }
    }

    /// Nombre de titres, place avant et après (estimée d'après leur durée), et rappel du Wi-Fi.
    private var qualityUpdateSummary: String {
        let kbps: Int64 = switch player.downloadQuality {
        case .flac: 1000
        case .mp3High: 320
        case .mp3Low: 128
        }
        let before = qualityChanges.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        let after = qualityChanges.reduce(Int64(0)) { $0 + Int64($1.track.durationS) * kbps * 125 }
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let text = tr("%@ titres seront retéléchargés en %@ (environ %@ → %@). Ils restent écoutables pendant la mise à jour.",
                      "\(qualityChanges.count)", player.downloadQuality.title, size(before), size(after))
        return downloadsWifiOnly ? text : text + " " + tr("Conseillé en Wi-Fi.")
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
                    coverBytes = 0 // le système efface le disque un peu après : relu tout de suite, l'ancienne taille restait
                    player.showToast(tr("Pochettes effacées"))
                }
                Button(tr("Annuler"), role: .cancel) {}
            } message: {
                Text(tr("Seules les pochettes gardées pour un affichage rapide sont effacées. Elles sont retéléchargées quand elles réapparaissent à l'écran. Tes téléchargements, ta session, ton historique et tes réglages ne sont pas touchés."))
            }
            divider
            // Ce qui prend vraiment de la place : les téléchargements. Leur taille, et leur page pour en supprimer : ouverte
            // dans la Bibliothèque, Réglages fermés. Ouverte ici, ses menus, ses messages et ses pages ne s'affichaient pas
            // (ils sont posés sous la feuille des Réglages).
            Button {
                dismiss()
                player.openDownloadsPage += 1
            } label: {
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

    /// Interrupteur : icône et titre, et une précision seulement quand le titre ne suffit pas.
    private func toggle(_ icon: String, _ title: String, _ isOn: Binding<Bool>, detail: String? = nil,
                        iconColor: Color? = nil) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(iconColor ?? Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .tint(Theme.accent)
        .padding(14)
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
            .accessibilityAddTraits(q == selected ? .isSelected : []) // VoiceOver dit laquelle est choisie
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
                .accessibilityAddTraits(p.id == current ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: current)
    }
}

/// Ligne de réglage : icône de la couleur de l'app, et titre.
struct SettingLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(title)
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

    var icon: String {
        switch self {
        case .flac: "waveform"
        case .mp3High: "music.note"
        case .mp3Low: "antenna.radiowaves.left.and.right"
        }
    }

    var rate: String {
        switch self {
        case .flac: tr("Sans perte")
        case .mp3High: "320 kbit/s"
        case .mp3Low: "128 kbit/s"
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
                    SettingLabel(tr("Flow sur l'accueil"), icon: "waveform")
                }
                Toggle(isOn: Binding(get: { player.lovedOnHome }, set: { player.setLovedOnHome($0) })) {
                    SettingLabel(tr("%@ sur l'accueil", player.lovedTitle), icon: "heart.fill")
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { player.reco.enabled },
                    set: { on in player.updateReco { r in
                        r.enabled = on
                        if on && r.order.allSatisfy(r.hidden.contains) { r.hidden = RecoPrefs().hidden } // tout était masqué : on revient aux catégories de base
                    } }
                )) {
                    SettingLabel(tr("Recommandations"), icon: "sparkles")
                }
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
                    Text(tr("Fais glisser pour changer l'ordre."))
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
        .scrollContentBackground(.hidden)
        // Même fond que les autres pages des Réglages.
        .sheetBackground(Theme.accent, strength: 0.3)
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
