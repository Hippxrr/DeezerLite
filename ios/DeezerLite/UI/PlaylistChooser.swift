import SwiftUI

/// Appui long sur un titre > « Ajouter à une playlist » : ses playlists, et « Nouvelle playlist » pour en créer une
/// qui contient déjà ce titre.
struct PlaylistChooser: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { name = ""; naming = true } label: {
                        Label(tr("Nouvelle playlist"), systemImage: "plus")
                    }
                }
                Section(tr("Mes playlists")) {
                    if player.library[0] == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if player.ownedPlaylists.isEmpty {
                        Text(tr("Tu n'as pas encore créé de playlist.")).foregroundStyle(.secondary)
                    }
                    ForEach(player.ownedPlaylists, id: \.id) { card in
                        Button {
                            player.addToPlaylist(card, track)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(url: player.coverURL(card), side: 44, radius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.title).lineLimit(1)
                                    if !card.subtitle.isEmpty {
                                        Text(card.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(tr("Ajouter à une playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annuler")) { dismiss() } }
            }
            .newPlaylistPrompt(isPresented: $naming, name: $name) { title in
                Task { if await player.createPlaylist(title, with: [track]) { dismiss() } }
            }
        }
        .task { await player.loadLibrary(0, force: false) }
    }
}

/// « Supprimer la playlist » dans l'appui long sur une de ses playlists (confirmation demandée ensuite, voir RootView).
struct DeletePlaylistMenu: View {
    @Environment(Player.self) private var player
    let card: Card

    var body: some View {
        if card.kind == "playlist" && card.owned {
            Button(role: .destructive) { player.deletingPlaylist = card } label: {
                Label(tr("Supprimer la playlist"), systemImage: "trash")
            }
        }
    }
}

extension View {
    /// Fenêtre « Nouvelle playlist » : un nom, puis « Créer ».
    func newPlaylistPrompt(isPresented: Binding<Bool>, name: Binding<String>, create: @escaping (String) -> Void) -> some View {
        alert(tr("Nouvelle playlist"), isPresented: isPresented) {
            TextField(tr("Nom de la playlist"), text: name)
            Button(tr("Annuler"), role: .cancel) {}
            Button(tr("Créer")) { create(name.wrappedValue) }
                .disabled(name.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
