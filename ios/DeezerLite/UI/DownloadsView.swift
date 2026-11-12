import SwiftUI

struct DownloadsView: View {
    @Environment(Player.self) private var player
    @Environment(\.openRoute) private var openRoute
    @State private var confirmClear = false

    /// Créé une seule fois (un formateur par rendu coûtait pour rien).
    private static let byteFormatter = ByteCountFormatter()
    /// Lignes affichées au plus dans « Téléchargements en cours ».
    private static let maxActiveRows = 6

    private var isEmpty: Bool {
        player.downloadCollections.isEmpty && player.downloads.isEmpty
    }

    /// Téléchargements en cours d'abord, puis échecs, dans l'ordre de la file : les lignes ne changent plus de place
    /// à chaque mise à jour, et des échecs ne cachent plus les téléchargements qui avancent.
    private var active: [DownloadUpdate] {
        let states = player.downloadStates
        let rank = Dictionary(player.downloadQueueOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = states.values.filter { $0.state != .queued }
        let sorted = visible.sorted { a, b in
            let pa = a.state == .downloading ? 0 : 1
            let pb = b.state == .downloading ? 0 : 1
            if pa != pb { return pa < pb }
            let ra = rank[a.id] ?? Int.max, rb = rank[b.id] ?? Int.max
            return ra != rb ? ra < rb : a.id < b.id
        }
        return Array(sorted.prefix(Self.maxActiveRows))
    }

    private var queuedCount: Int {
        player.downloadStates.values.reduce(into: 0) { count, update in
            if update.state == .queued { count += 1 }
        }
    }

    private var failedCount: Int {
        player.downloadStates.values.reduce(into: 0) { count, update in
            if update.state == .failed { count += 1 }
        }
    }

    private var hasActivity: Bool {
        queuedCount > 0 || player.downloadStates.values.contains { $0.state == .downloading }
    }

    private var storage: String {
        Self.byteFormatter.string(fromByteCount: Int64(player.downloadBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if hasActivity {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("tr("Téléchargements en cours")).font(.title3.bold())
                        if queuedCount > 0 {
                            Text("\(queuedCount) en attente").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { player.cancelAllDownloads() } label: {
                        Label("tr("Tout arrêter"), systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            } else if failedCount > 0 {
                Text("tr("Téléchargements en échec")).font(.title3.bold())
            }

            if !active.isEmpty {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(active, id: \.id) { update in
                        activeRow(update)
                    }
                }
            }

            if failedCount > 0 {
                HStack {
                    Text(failedCount == 1 ? "1 échec" : "\(failedCount) échecs")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("tr("Tout réessayer")) { retryFailed() }
                        .font(.subheadline.weight(.semibold))
                    Button("tr("Effacer"), role: .destructive) { player.clearFailedDownloads() }
                        .font(.subheadline.weight(.semibold))
                }
            }

            if isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 38))
                        .foregroundStyle(Theme.accent)
                    Text(hasActivity ? tr("Les titres terminés apparaîtront ici") : tr("Aucun téléchargement"))
                        .font(.headline)
                    Text(tr("Télécharge un titre, un album ou une playlist pour les écouter sans connexion, en Wi-Fi comme en 4G/5G."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("tr("Sur ce téléphone")).font(.title3.bold())
                        Text(storage).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { confirmClear = true } label: {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 38, height: 38)
                            .surface(Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("tr("Effacer tous les téléchargements"))
                }

                if !player.downloadCollections.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("tr("Playlists et albums")).font(.headline)
                        ForEach(player.downloadCollections, id: \.key) { collection in
                            Button { openRoute(route(collection)) } label: {
                                ItemRow(title: title(collection),
                                        subtitle: "\(collection.downloaded)/\(collection.total) titres disponibles") {
                                    CardArt(card: card(collection))
                                }
                            }
                            .buttonStyle(.pressable)
                            .contextMenu {
                                Button(role: .destructive) { player.removeDownloadCollection(collection) } label: {
                                    Label("tr("Supprimer le téléchargement"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !player.downloads.isEmpty {
                    Text("tr("Titres individuels")).font(.headline)
                    HStack(spacing: 12) {
                        Button { player.play(player.downloads, at: 0) } label: {
                            Label("tr("Lecture"), systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(Theme.onAccent)
                                .surface(Capsule(), tint: Theme.accent)
                        }
                        Button {
                            if !player.shuffle { player.toggleShuffle() }
                            player.play(player.downloads, at: Int.random(in: player.downloads.indices))
                        } label: {
                            Label("tr("Aléatoire"), systemImage: "shuffle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(.white)
                                .surface(Capsule())
                        }
                    }
                    .buttonStyle(.pressable)

                    LazyVStack(spacing: 14) {
                        ForEach(Array(player.downloads.enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track, list: player.downloads, index: i)
                        }
                    }
                }
            }
        }
        .confirmationDialog(tr("Effacer tous les téléchargements ?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("tr("Tout effacer"), role: .destructive) { player.clearDownloads() }
        } message: {
            Text(tr("Les fichiers audio et leurs pochettes seront supprimés de ce téléphone."))
        }
    }

    private func retryFailed() {
        let tracks = player.downloadStates.values
            .filter { $0.state == .failed }
            .compactMap { player.downloadTracks[$0.id] }
        if !tracks.isEmpty { player.download(tracks) }
    }

    /// Nom actuel dans la bibliothèque (playlist renommée sur Deezer…), sinon celui gardé au téléchargement.
    private func title(_ collection: DownloadCollection) -> String {
        if collection.kind == "loved" { return player.lovedTitle }
        let tab = collection.kind == "album" ? 1 : 0
        return player.library[tab]?.first { $0.kind == collection.kind && $0.id == collection.id }?.title ?? collection.title
    }

    private func route(_ collection: DownloadCollection) -> Route {
        if collection.kind == "loved" { return .loved }
        return .detail(kind: collection.kind, id: collection.id, title: title(collection))
    }

    private func card(_ collection: DownloadCollection) -> Card {
        Card(kind: collection.kind, id: collection.id, title: title(collection),
             subtitle: collection.subtitle, coverUrl: collection.coverUrl,
             owned: collection.owned, key: "")
    }

    @ViewBuilder
    private func activeRow(_ update: DownloadUpdate) -> some View {
        let track = player.downloadTracks[update.id]
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? tr("Titre")).font(.body.weight(.medium)).lineLimit(1)
                    Text(track?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(label(update)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if update.state == .queued || update.state == .downloading {
                    Button { player.cancelDownload(update.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            // Zone d'appui de 44 points, la taille minimale recommandée par Apple (l'icône seule en faisait ~17).
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("tr("Annuler le téléchargement"))
                } else if update.state == .failed {
                    if let track {
                        Button("tr("Réessayer")) { player.download([track]) }
                            .font(.caption.weight(.semibold))
                    }
                    Button { player.cancelDownload(update.id) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            // Zone d'appui de 44 points, la taille minimale recommandée par Apple (l'icône seule en faisait ~17).
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("tr("Retirer de la liste"))
                }
            }
            if update.state == .downloading {
                ProgressView(value: update.progress).tint(Theme.accent)
            } else if let error = update.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(12)
        .surface(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: false)
    }

    private func label(_ update: DownloadUpdate) -> String {
        switch update.state {
        case .queued: tr("En attente")
        case .downloading: "\(Int(update.progress * 100)) %"
        case .failed: tr("Échec")
        case .complete, .cancelled: ""
        }
    }
}
