import SwiftUI

/// « Qui écoute ? » : choix du profil d'un compte Deezer Famille, à la première connexion (fenêtre) et dans les réglages
/// (page). Le choix est gardé sur le téléphone et rouvert à chaque lancement.
struct ProfilePicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { ProfileGrid().padding(24) }
                .sheetBackground(Theme.accent, strength: 0.3)
                .navigationTitle(tr("Qui écoute ?"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() }.fontWeight(.semibold) }
                }
        }
        .tint(Theme.accent)
    }
}

/// Réglages > Compte Deezer > Changer de profil.
struct ProfilePage: View {
    var body: some View {
        ScrollView { ProfileGrid().padding(24) }
            .sheetBackground(Theme.accent, strength: 0.3)
            .navigationTitle(tr("Changer de profil"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Les profils en grille ; un appui ouvre le profil (le profil ouvert est entouré).
struct ProfileGrid: View {
    @Environment(Player.self) private var player

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 20)], spacing: 26) {
            ForEach(player.profiles, id: \.id) { p in
                Button { Task { await player.switchProfile(p) } } label: { ProfileBadge(profile: p, side: 92) }
                    .buttonStyle(.pressable)
                    .disabled(player.switchingProfile)
            }
        }
        .overlay { if player.switchingProfile { ProgressView().controlSize(.large) } }
        .sensoryFeedback(.selection, trigger: player.currentProfile?.id)
    }
}

/// Photo du profil, son nom, et ce qu'il est : ouvert en ce moment, enfant, titulaire.
struct ProfileBadge: View {
    let profile: Profile
    let side: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ProfileAvatar(profile: profile, side: side)
                .padding(4)
                .overlay { Circle().strokeBorder(profile.current ? Theme.accent : .clear, lineWidth: 3) }
            Text(profile.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(profile.current ? tr("Profil ouvert") : profile.kid ? tr("Enfant") : profile.main ? tr("Titulaire") : " ")
                .font(.caption)
                .foregroundStyle(profile.current ? Theme.accent : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Haut des pages principales (Accueil, Recherche, Bibliothèque) : leur nom en gros, et à droite la photo du profil
/// ouvert, qui ouvre les Réglages.
struct PageTitleBar: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            ProfileButton()
        }
    }
}

/// Photo du profil ouvert (son initiale s'il n'en a pas) : ouvre les Réglages, comme l'engrenage avant.
struct ProfileButton: View {
    @Environment(Player.self) private var player
    @State private var showSettings = false
    private let side: CGFloat = 40

    var body: some View {
        Button { showSettings = true } label: {
            Group {
                if let profile = player.currentProfile {
                    ProfileAvatar(profile: profile, side: side)
                } else {
                    // Profils pas encore chargés.
                    Image(systemName: "person.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: side, height: side)
                        .background(Theme.card, in: Circle())
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tr("Réglages"))
        .sheet(isPresented: $showSettings) { SettingsView().environment(player) }
    }
}

/// Photo du profil, ou son initiale sur la couleur du thème s'il n'en a pas.
struct ProfileAvatar: View {
    let profile: Profile
    let side: CGFloat

    var body: some View {
        if let url = profile.pictureUrl {
            CoverView(url: url, side: side, round: true)
        } else {
            Text(String(profile.name.prefix(1)).uppercased())
                .font(.system(size: side * 0.42, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: side, height: side)
                .background(Theme.accent, in: Circle())
        }
    }
}
