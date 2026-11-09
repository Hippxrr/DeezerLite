import SwiftUI

/// Réglages > Dernières écoutes : les 5 dernières écoutes de l'historique officiel de Deezer. Une écoute qui apparaît
/// ici compte dans les statistiques (My Deezer Month, récap de l'année).
struct RecentListensPage: View {
    @Environment(Player.self) private var player
    @State private var listens: [RecentListen]?
    @State private var failure: String?
    @State private var loading = false
    /// Profil de l'historique affiché.
    @State private var epoch = -1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Ton historique officiel Deezer. Une écoute part vers Deezer à la fin du titre, après au moins 30 s d'écoute ; tire vers le bas pour actualiser."))
                    .font(.footnote).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    if let listens, !listens.isEmpty {
                        ForEach(Array(listens.enumerated()), id: \.offset) { i, l in
                            if i > 0 { Divider().padding(.leading, 70) }
                            HStack(spacing: 12) {
                                CoverView(url: l.coverUrl, side: 44, radius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(l.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                // Mis à jour chaque minute (« il y a 5 min » ne reste pas figé).
                                TimelineView(.periodic(from: .now, by: 60)) { _ in
                                    Text(Self.when(l.listenedAt)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                        }
                    } else if let failure {
                        Text(failure).font(.subheadline).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity)
                    } else if listens != nil {
                        Text(tr("Aucune écoute pour l'instant.")).font(.subheadline).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity)
                    } else {
                        ProgressView().padding(24).frame(maxWidth: .infinity)
                    }
                }
                .surface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
            }
            .padding(16)
        }
        .refreshable { await load() }
        .navigationTitle(tr("Dernières écoutes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(loading)
        }
        // Rechargé aussi au changement de profil (chaque profil a son historique).
        .task(id: player.profileEpoch) { await load() }
    }

    private func load() async {
        guard let core = player.core else { return }
        let asked = player.profileEpoch
        // Autre profil : l'historique de l'ancien n'est plus affiché pendant le chargement.
        if asked != epoch { listens = nil; failure = nil; epoch = asked }
        loading = true
        defer { loading = false }
        do {
            let list = try await core.recentListens()
            guard asked == player.profileEpoch else { return } // réponse pour le profil d'avant
            listens = list
            failure = nil
        } catch {
            guard asked == player.profileEpoch else { return }
            failure = tr("Impossible de lire l'historique : %@", player.describe(error))
        }
    }

    /// « à l'instant », « il y a 5 min », « aujourd'hui à 19:24 », « hier à 08:10 », « 3 nov. à 19:24 ».
    private static func when(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return tr("à l'instant") }
        if minutes < 60 { return tr("il y a %@ min", "\(minutes)") }
        let locale = LanguageStore.shared.locale
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        if Calendar.current.isDateInToday(date) { return tr("aujourd'hui à %@", time) }
        if Calendar.current.isDateInYesterday(date) { return tr("hier à %@", time) }
        return tr("%@ à %@", date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(locale)), time)
    }
}
