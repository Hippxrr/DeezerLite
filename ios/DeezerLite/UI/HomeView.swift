import SwiftUI

struct HomeView: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @State private var reordering = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitleBar(title: tr("Accueil"))
                    .padding(.horizontal, 16)
                    .padding(.bottom, -12)
                // Flow, titres aimés, épinglés : appui long puis « Réorganiser l'accueil » pour changer l'ordre.
                VStack(spacing: 12) {
                    ForEach(player.homeItems, id: \.id) { item in row(item) }
                }
                .padding(.horizontal, 16)
                .animation(.snappy(duration: 0.3), value: player.homeItems.map(\.id))
                if !player.reco.anyVisible {
                    // Recommandations désactivées dans Réglages : rien n'est demandé à Deezer.
                    EmptyView()
                } else if let all = player.home {
                    let shelves = player.reco.shelves(all)
                    // Rangées identifiées par leur contenu, pas leur rang : en masquer une ne donne plus sa place (et son
                    // défilement) à la suivante.
                    ForEach(ShelfSlot.slots(shelves)) { slot in
                        let i = slot.index
                        let kind = shelves[i].kind
                        let hide = { withAnimation { player.updateReco { $0.hidden.append(kind) } } }
                        if kind == "track-mixes" {
                            TrackMixShelf(title: shelves[i].title, cards: shelves[i].items, hideLabel: RecoPrefs.label(kind), onHide: hide)
                        } else {
                            ShelfRow(title: shelves[i].title, cards: shelves[i].items, hideLabel: RecoPrefs.label(kind), onHide: hide)
                        }
                    }
                    .transition(.opacity)
                } else {
                    SkeletonShelf()
                    SkeletonShelf()
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.25), value: player.home == nil)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $reordering) {
            HomeOrderView().environment(player).presentationDetents([.medium, .large])
        }
        .refreshable { await player.loadHome(force: true) }
        .task { await player.loadHome(force: false) }
    }

    @ViewBuilder
    private func row(_ item: HomeItem) -> some View {
        switch item {
        case .flow:
            Button { player.playFlow() } label: {
                ItemRow(title: "Flow", subtitle: "", trailing: nil) { FlowArt() }
            }
            .buttonStyle(.pressable)
            .contextMenu {
                Button { withAnimation { player.setFlowOnHome(false) } } label: {
                    Label(tr("Retirer de l'accueil"), systemImage: "rectangle.stack.badge.minus")
                }
                CoverMenu(card: Player.flowCard)
                reorderButton
            }
        case .loved:
            LovedRow { openRoute(.loved) }
                .contextMenu {
                    DownloadCollectionMenu(card: player.lovedMenuCard)
                    Button { withAnimation { player.setLovedOnHome(false) } } label: {
                        Label(tr("Retirer de l'accueil"), systemImage: "rectangle.stack.badge.minus")
                    }
                    RenameLovedMenu()
                    CoverMenu(card: player.lovedMenuCard)
                    reorderButton
                }
        case .pin(let pin):
            CardRow(card: pin.card, onReorder: player.homeItems.count > 1 ? { reordering = true } : nil)
        }
    }

    @ViewBuilder
    private var reorderButton: some View {
        if player.homeItems.count > 1 {
            Button { reordering = true } label: { Label(tr("Réorganiser l'accueil"), systemImage: "arrow.up.arrow.down") }
        }
    }
}

/// Ordre du haut de l'accueil : une liste avec des poignées, on glisse chaque élément à sa place.
private struct HomeOrderView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(player.homeItems, id: \.id) { item in
                        HStack(spacing: 12) {
                            art(item)
                            Text(title(item)).lineLimit(1)
                        }
                    }
                    .onMove { from, to in
                        var ids = player.homeItems.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        player.setHomeOrder(ids)
                    }
                } footer: {
                    Text(tr("Fais glisser avec les poignées à droite."))
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .sheetBackground(Theme.accent, strength: 0.3)
            .navigationTitle(tr("Réorganiser l'accueil"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() }.fontWeight(.semibold) }
            }
            .sensoryFeedback(.selection, trigger: player.homeItems.map(\.id))
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func art(_ item: HomeItem) -> some View {
        switch item {
        case .flow: FlowArt(side: 40)
        case .loved:
            if let url = player.lovedCover { CoverView(url: url, side: 40, radius: 8) } else { LovedArt(side: 40, radius: 8) }
        case .pin(let pin): CardArt(card: pin.card, side: 40)
        }
    }

    private func title(_ item: HomeItem) -> String {
        switch item {
        case .flow: "Flow"
        case .loved: player.lovedTitle
        case .pin(let pin): pin.title
        }
    }
}

/// Titres aimés : la pochette choisie sur Deezer (ou le cœur), comme une playlist.
private struct LovedRow: View {
    @Environment(Player.self) private var player
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ItemRow(title: player.lovedTitle, subtitle: player.lovedIds.count == 1 ? tr("1 titre") : tr("%@ titres", "\(player.lovedIds.count)")) {
                if let url = player.lovedCover {
                    CoverView(url: url, side: 64, radius: 10)
                } else {
                    LovedArt(side: 64, radius: 10)
                }
            }
        }
        .buttonStyle(.pressable)
    }
}

/// « Mixes inspirés par » : des titres en colonnes de 3, qu'on fait défiler sur le côté ; un appui lance le mix du titre.
private struct TrackMixShelf: View {
    @Environment(Player.self) private var player
    let title: String
    let cards: [Card]
    let hideLabel: String
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).padding(.horizontal, 16)
                .contextMenu {
                    Button(role: .destructive, action: onHide) { Label(tr("Masquer « %@ » de l'accueil", hideLabel), systemImage: "eye.slash") }
                }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(64), spacing: 10), count: min(3, cards.count)), spacing: 12) {
                    ForEach(cards.indices, id: \.self) { i in row(cards[i]) }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func row(_ card: Card) -> some View {
        Button { player.playTrackMix(card.id) } label: {
            HStack(spacing: 12) {
                CoverView(url: card.coverUrl, side: 64, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // Colonne un peu plus étroite que l'écran : la suivante dépasse, on voit qu'on peut glisser.
        .containerRelativeFrame(.horizontal) { width, _ in width - 56 }
    }
}

/// Rangée de l'accueil : son type et son titre (numérotés s'ils se répètent), et sa place dans la liste.
private struct ShelfSlot: Identifiable {
    let id: String
    let index: Int

    static func slots(_ shelves: [Shelf]) -> [ShelfSlot] {
        var seen: [String: Int] = [:]
        return shelves.indices.map { i in
            let key = "\(shelves[i].kind)|\(shelves[i].title)"
            seen[key, default: 0] += 1
            return ShelfSlot(id: "\(key)|\(seen[key] ?? 0)", index: i)
        }
    }
}
