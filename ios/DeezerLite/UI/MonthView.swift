import SwiftUI

/// « Mon mois » (Bibliothèque) : le récap mensuel officiel de Deezer (My Deezer Month) — temps d'écoute, titres,
/// artistes et genres du mois, avec les flèches pour passer d'un mois à l'autre.
struct MonthView: View {
    @Environment(Player.self) private var player
    /// Change à chaque « tirer pour actualiser » de la Bibliothèque : le mois est redemandé.
    var refresh = 0
    @Environment(\.openRoute) private var openRoute
    /// Mois affiché ; `nil` : le dernier disponible.
    @State private var which: StatMonth?
    @State private var stats: MonthStats?
    @State private var phase = Phase.loading
    /// Mois en cours de chargement (le mois affiché reste, un peu estompé).
    @State private var loading = false
    /// Profil des données affichées : un autre profil repart de son dernier mois.
    @State private var epoch = -1
    /// Image du mois prête à partager.
    @State private var shared: SharedImage?
    @State private var preparing = false

    private struct SharedImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private enum Phase { case loading, empty, failed(String), ready }

    /// Nom du mois (1 à 12) dans la langue de l'app, avec sa majuscule.
    private static func monthName(_ month: UInt32) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        return formatter.standaloneMonthSymbols[Int(max(1, min(12, month))) - 1].capitalized(with: formatter.locale)
    }

    private static var periods: [String: String] { ["morning": tr("le matin"), "afternoon": tr("l'après-midi"), "evening": tr("le soir"), "night": tr("la nuit")] }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            case .empty:
                message(tr("Pas encore de récap : Deezer le prépare après au moins un quart d'heure d'écoute dans le mois."))
            case .failed(let text):
                message(text)
                Button(tr("Réessayer")) { Task { await load() } }.frame(maxWidth: .infinity)
            case .ready:
                if let stats {
                    content(stats)
                        .opacity(loading ? 0.5 : 1)
                        .overlay(alignment: .top) { if loading { ProgressView().padding(.top, 60) } }
                        .allowsHitTesting(!loading)
                }
            }
        }
        .sheet(item: $shared) { ActivitySheet(items: [$0.image]).presentationDetents([.medium, .large]) }
        // Rechargé au changement de mois, de profil (chaque profil a ses statistiques) et à l'actualisation.
        .task(id: "\(which?.year ?? 0)-\(which?.month ?? 0)-\(player.profileEpoch)-\(refresh)") { await load() }
    }

    private func load() async {
        guard let core = player.core else { return }
        // Autre profil : ses données à lui, à partir de son dernier mois (celui affiché n'existe peut-être pas pour lui).
        if epoch != player.profileEpoch {
            if epoch != -1 {
                epoch = player.profileEpoch
                stats = nil
                if which != nil { which = nil; return } // la tâche repart avec le nouveau mois
            }
            epoch = player.profileEpoch
        }
        if stats == nil { phase = .loading }
        loading = true
        defer { loading = false }
        do {
            let s = try await core.monthStats(year: which?.year ?? 0, month: which?.month ?? 0)
            // Réponse d'une demande remplacée (autre mois, autre profil) : ignorée.
            guard !Task.isCancelled else { return }
            stats = s
            phase = s == nil ? .empty : .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(player.describe(error))
        }
    }

    /// Prépare l'image du mois (format story) puis ouvre le partage.
    private func shareImage(_ s: MonthStats, title: String) async {
        preparing = true
        defer { preparing = false }
        let loader = CoverLoader.shared
        var face: UIImage?
        if let url = s.topArtists.first?.pictureUrl { face = await loader.image(url: url, pixels: 500) }
        var covers: [UIImage?] = []
        for t in s.topTracks.prefix(5) {
            var cover: UIImage?
            if let url = t.coverUrl { cover = await loader.image(url: url, pixels: 250) }
            covers.append(cover)
        }
        let card = MonthCard(stats: s, title: title, time: Self.duration(s.minutes), accent: Theme.accent, face: face, covers: covers)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage { shared = SharedImage(image: image) }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.top, 30)
    }

    @ViewBuilder
    private func content(_ s: MonthStats) -> some View {
        let at = s.months.firstIndex { $0.year == s.year && $0.month == s.month }
        let older = at.flatMap { s.months.indices.contains($0 + 1) ? s.months[$0 + 1] : nil }
        let newer = at.flatMap { $0 > 0 ? s.months[$0 - 1] : nil }

        HStack {
            Button { which = older } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .disabled(older == nil)
                .accessibilityLabel(tr("Mois précédent"))
            Spacer()
            Text("\(Self.monthName(s.month)) \(String(s.year))")
                .font(.title2.weight(.bold))
                .contentTransition(.opacity)
            Spacer()
            Button { which = newer } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(newer == nil)
                .accessibilityLabel(tr("Mois suivant"))
        }
        .buttonStyle(.pressable)
        .foregroundStyle(.primary)
        .sensoryFeedback(.selection, trigger: s.month)

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile(Self.duration(s.minutes), tr("d'écoute"), note: listenNote(s))
            tile(Int(s.streams).formatted(), tr("écoutes"))
            tile(Int(s.tracks).formatted(), tr("titres différents"), note: s.discovered > 0 ? tr("dont %@ découverts", "\(s.discovered)") : nil)
            tile(Int(s.artists).formatted(), tr("artistes"))
        }

        if let p = s.period {
            Text(tr("Tu écoutes surtout %@.", Self.periods[p] ?? p)).font(.subheadline).foregroundStyle(.secondary)
        }

        if !s.topArtists.isEmpty {
            section(tr("Tes artistes du mois")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(s.topArtists.enumerated()), id: \.element.id) { i, a in
                            Button { openRoute(.detail(kind: "artist", id: a.id, title: a.name)) } label: {
                                VStack(spacing: 6) {
                                    CoverView(url: a.pictureUrl, side: 96, round: true)
                                    Text("\(i + 1). \(a.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(Self.duration(a.minutes)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 104)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
            }
        }

        if !s.topTracks.isEmpty {
            section(tr("Tes titres du mois")) {
                VStack(spacing: 4) {
                    ForEach(Array(s.topTracks.enumerated()), id: \.element.id) { i, t in
                        Button {
                            if t.albumId != 0 { openRoute(.detail(kind: "album", id: t.albumId, title: t.title)) }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                CoverView(url: t.coverUrl, side: 48, radius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(t.streams > 1 ? tr("%@ écoutes", "\(t.streams)") : tr("%@ écoute", "\(t.streams)")).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .disabled(t.albumId == 0)
                    }
                }
            }
        }

        if !s.topGenres.isEmpty {
            let top = Double(max(1, s.topGenres.map(\.minutes).max() ?? 1))
            section(tr("Tes genres")) {
                VStack(spacing: 14) {
                    ForEach(s.topGenres, id: \.name) { g in
                        VStack(spacing: 6) {
                            HStack {
                                Text(g.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Self.duration(g.minutes)).font(.caption).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.1))
                                    Capsule().fill(Theme.accent).frame(width: geo.size.width * Double(g.minutes) / top)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }
        }

        Button {
            let name = Self.monthName(s.month)
            Task { await shareImage(s, title: "\(name) \(String(s.year))") }
        } label: {
            Label(preparing ? tr("Préparation…") : tr("Partager mon mois"), systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .disabled(preparing)

        Text(tr("Statistiques officielles de Deezer (My Deezer Month), mises à jour par Deezer."))
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func listenNote(_ s: MonthStats) -> String? {
        var parts: [String] = []
        if let prev = s.previousMinutes, prev > 0 {
            let diff = Int((Double(s.minutes) - Double(prev)) / Double(prev) * 100)
            parts.append(tr("%@ sur un mois", "\(diff >= 0 ? "+" : "−")\(abs(diff)) %"))
        }
        if s.averageMinutes > 0 { parts.append(tr("Moyenne Deezer : %@", Self.duration(s.averageMinutes))) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func tile(_ value: String, _ label: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title.weight(.heavy)).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.subheadline.weight(.semibold))
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    /// 3 660 min → « 61 h » ; moins d'une heure → « 42 min ».
    private static func duration(_ minutes: UInt32) -> String {
        minutes >= 60 ? "\(Int((Double(minutes) / 60).rounded()).formatted()) h" : "\(minutes) min"
    }
}

/// Feuille de partage d'iOS pour une image (ShareLink ne peut pas attendre qu'elle soit préparée).
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Image du mois à partager, au format story (360 x 640 points, rendus à 1080 x 1920).
private struct MonthCard: View {
    let stats: MonthStats
    let title: String
    let time: String
    let accent: Color
    let face: UIImage?
    let covers: [UIImage?]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Mon mois")).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(size: 31, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(time).font(.system(size: 50, weight: .heavy)).padding(.top, 18)
            Text(tr("d'écoute")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(tr("%@ écoutes · %@ titres · %@ artistes", Int(stats.streams).formatted(), Int(stats.tracks).formatted(), Int(stats.artists).formatted()))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.top, 8)
            if let artist = stats.topArtists.first {
                HStack(spacing: 14) {
                    picture(face, side: 66, radius: 33)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Artiste du mois")).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        Text(artist.name).font(.system(size: 20, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                .padding(.top, 20)
            }
            if !stats.topTracks.isEmpty {
                Text(tr("Mes titres du mois")).font(.system(size: 15, weight: .bold)).padding(.top, 22).padding(.bottom, 10)
            }
            ForEach(Array(stats.topTracks.prefix(5).enumerated()), id: \.offset) { i, t in
                HStack(spacing: 11) {
                    Text("\(i + 1)").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white.opacity(0.6)).frame(width: 14)
                    picture(covers.indices.contains(i) ? covers[i] : nil, side: 42, radius: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text(t.artist).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .padding(.bottom, 8)
            }
            Spacer(minLength: 0)
            if let genre = stats.topGenres.first {
                Text(tr("Genre du mois : %@", genre.name)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 34)
        .frame(width: 360, height: 640, alignment: .topLeading)
        .background(LinearGradient(stops: [.init(color: accent, location: 0), .init(color: Color(white: 0.08), location: 0.62), .init(color: Color(white: 0.04), location: 1)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private func picture(_ image: UIImage?, side: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.white.opacity(0.12) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
