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
    private static let previewScale: CGFloat = 0.5

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
                        Button { share(image) } label: { Text(tr("Partager")).bold() }
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

    /// Feuille de partage d'iOS. Une fois l'action faite (enregistrée dans Photos, envoyée…), la page se ferme et on
    /// revient au lecteur ; annulée, on reste ici pour changer les lignes.
    private func share(_ image: UIImage) {
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { @MainActor in dismiss() }
        }
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        guard var top = root else { return }
        while let shown = top.presentedViewController { top = shown }
        // iPad : la feuille s'affiche en bulle, accrochée au milieu de l'écran.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(sheet, animated: true)
    }

    /// Image de 1080 × 1920 (format story d'Instagram).
    private func render() {
        let renderer = ImageRenderer(content: LyricsCard(track: request.track, lines: chosen, cover: cover, backdrop: backdrop))
        renderer.scale = 3
        image = renderer.uiImage
    }
}

/// Carte partagée (format story) : pochette floutée en fond, pochette, titre et artiste en haut, les lignes en grand,
/// entre guillemets, au milieu.
struct LyricsCard: View {
    static let size = CGSize(width: 360, height: 640) // 9:16, format story
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
                // Entre guillemets : ouvrant sur la première ligne, fermant sur la dernière.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text((i == 0 ? "“" : "") + lines[i] + (i == lines.count - 1 ? "”" : ""))
                    }
                }
                .font(.system(size: fontSize, weight: .heavy))
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                Spacer(minLength: 16)
            }
            .foregroundStyle(.white)
            // Marges hautes et basses de story : la barre du profil et le champ de réponse d'Instagram ne cachent rien.
            .padding(.horizontal, 26)
            .padding(.vertical, 80)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    /// Plus il y a de texte, plus il est petit : la carte reste lisible et rien ne déborde.
    private var fontSize: CGFloat {
        switch lines.joined().count {
        case ..<60: 32
        case ..<120: 27
        case ..<200: 23
        default: 19
        }
    }
}
