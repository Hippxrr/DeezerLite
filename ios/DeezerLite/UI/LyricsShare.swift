import SwiftUI

/// Paroles à partager en image : demandé par un appui long sur une ligne (lecteur, panneau des paroles).
struct LyricsShareRequest: Identifiable {
    let id = UUID()
    let track: Track
    let lines: [LyricLine]
    /// Ligne appuyée : déjà cochée à l'ouverture.
    let first: Int
}

/// Choix des lignes (jusqu'à `maxLines`) avec l'aperçu de la carte, puis partage de l'image (Messages, Instagram,
/// Photos…). L'image est refaite seulement quand le choix change.
struct LyricsShareSheet: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let request: LyricsShareRequest
    @State private var picked: Set<Int>
    @State private var cover: UIImage?
    @State private var backdrop: UIImage?
    @State private var image: UIImage?
    @State private var refused = 0

    private static let maxLines = 6
    private static let previewScale: CGFloat = 0.62

    init(request: LyricsShareRequest) {
        self.request = request
        _picked = State(initialValue: [request.first])
    }

    private var chosen: [String] {
        picked.sorted().map { request.lines[$0].text.trimmingCharacters(in: .whitespaces) }
    }

    /// Lignes proposées : sans les lignes vides (pauses instrumentales).
    private var choices: [Int] {
        request.lines.indices.filter { !request.lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                LyricsCard(track: request.track, lines: chosen, cover: cover, backdrop: backdrop)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(Self.previewScale)
                    .frame(width: LyricsCard.size.width * Self.previewScale, height: LyricsCard.size.height * Self.previewScale)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    .accessibilityHidden(true)
                Text(tr("Jusqu'à %@ lignes", "\(Self.maxLines)")).font(.footnote).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(choices, id: \.self) { i in
                                let on = picked.contains(i)
                                Button { toggle(i) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(on ? Theme.accent : Color.secondary)
                                        Text(request.lines[i].text)
                                            .font(.body.weight(on ? .semibold : .regular))
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                                .id(i)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(request.first, anchor: .center) }
                }
            }
            .padding(.top, 8)
            .navigationTitle(tr("Partager les paroles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annuler")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let image, !picked.isEmpty {
                        let shown = Image(uiImage: image)
                        ShareLink(item: shown, preview: SharePreview(request.track.title, image: shown)) {
                            Text(tr("Partager")).bold()
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: picked)
        .sensoryFeedback(.warning, trigger: refused)
        .task {
            let url = player.coverFixes[request.track.id] ?? request.track.coverUrl
            if let url {
                async let c = CoverLoader.shared.image(url: url, pixels: 300)
                async let b = CoverLoader.shared.backdrop(url: url)
                (cover, backdrop) = await (c, b)
            }
            render()
        }
        .onChange(of: picked) { render() }
    }

    private func toggle(_ i: Int) {
        if picked.contains(i) {
            picked.remove(i)
        } else if picked.count < Self.maxLines {
            picked.insert(i)
        } else {
            refused += 1 // déjà le maximum : petite vibration, rien n'est ajouté
        }
    }

    /// Image de 1080 × 1350 (format portrait des réseaux sociaux).
    private func render() {
        let renderer = ImageRenderer(content: LyricsCard(track: request.track, lines: chosen, cover: cover, backdrop: backdrop))
        renderer.scale = 3
        image = renderer.uiImage
    }
}

/// Carte partagée : pochette floutée en fond, pochette, titre et artiste en haut, les lignes en grand au milieu.
struct LyricsCard: View {
    static let size = CGSize(width: 360, height: 450)
    let track: Track
    let lines: [String]
    let cover: UIImage?
    let backdrop: UIImage?

    var body: some View {
        ZStack {
            // Fond : la pochette floutée déjà préparée pour le lecteur (`CoverLoader.backdrop`), assombrie pour le texte.
            if let backdrop {
                Image(uiImage: backdrop).resizable().scaledToFill()
            } else {
                Theme.accent
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Group {
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.15)
                        }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 14, weight: .medium)).opacity(0.75).lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i])
                    }
                }
                .font(.system(size: fontSize, weight: .heavy))
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("Deezer Lite")
                }
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(26)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    /// Plus il y a de texte, plus il est petit : la carte reste lisible et rien ne déborde.
    private var fontSize: CGFloat {
        switch lines.joined().count {
        case ..<60: 28
        case ..<120: 24
        case ..<200: 20
        default: 17
        }
    }
}
