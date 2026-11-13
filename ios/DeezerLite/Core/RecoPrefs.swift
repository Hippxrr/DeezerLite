import Foundation

/// Recommandations de Deezer sur l'accueil : catégories activables et réordonnables, comme sur la version bureau.
struct RecoPrefs: Codable, Equatable {
    static let kinds: [(id: String, label: String)] = [
        ("recent", "Écouté récemment"), ("followed", "Playlists suivies"), ("new-releases", "Nouveautés pour toi"),
        ("playlists-for-you", "Playlists pour toi"), ("mixes", "Mixes pour toi"), ("track-mixes", "Mixes inspirés par"), ("on-repeat", "En boucle chez toi"),
        ("similar-artists", "Parce que tu aimes…"), ("curated", "Sélections de la rédaction"),
    ]

    static func label(_ kind: String) -> String { tr(kinds.first { $0.id == kind }?.label ?? kind) }

    var enabled = true
    var order: [String] = RecoPrefs.kinds.map { $0.id }
    /// « Mixes inspirés par » : coupés de base.
    var hidden: [String] = ["track-mixes"]
    /// Nombre maximal de sélections de la rédaction (0 à 12).
    var curatedMax = 4

    /// Au moins une catégorie visible : sinon inutile de demander l'accueil à Deezer.
    var anyVisible: Bool {
        enabled && order.contains { !hidden.contains($0) && !($0 == "curated" && curatedMax == 0) }
    }

    /// Rangées à afficher, dans l'ordre choisi.
    func shelves(_ all: [Shelf]) -> [Shelf] {
        guard enabled else { return [] }
        var out: [Shelf] = []
        for kind in order where !hidden.contains(kind) {
            var shown = 0
            for shelf in all where shelf.kind == kind {
                if kind == "curated" {
                    shown += 1
                    if shown > curatedMax { break }
                }
                out.append(shelf)
            }
        }
        return out
    }

    static func load() -> RecoPrefs {
        // Réglages d'une version d'avant : une seule fois, les mixes passent après « Mixes pour toi » et sont coupés.
        let mixesToSettle = !UserDefaults.standard.bool(forKey: "trackMixesSettled")
        UserDefaults.standard.set(true, forKey: "trackMixesSettled")
        guard let data = UserDefaults.standard.data(forKey: "reco"),
              var saved = try? JSONDecoder().decode(RecoPrefs.self, from: data) else { return RecoPrefs() }
        // Catégories ajoutées dans une version plus récente : placées juste après la première, pour être vues.
        let known = kinds.map { $0.id }
        let added = known.filter { !saved.order.contains($0) }
        saved.order = saved.order.filter(known.contains)
        saved.order.insert(contentsOf: added, at: min(1, saved.order.count))
        saved.hidden = saved.hidden.filter(known.contains)
        saved.curatedMax = min(max(saved.curatedMax, 0), 12)
        if mixesToSettle {
            saved.order.removeAll { $0 == "track-mixes" }
            let after = saved.order.firstIndex(of: "mixes").map { $0 + 1 } ?? saved.order.count
            saved.order.insert("track-mixes", at: after)
            if !saved.hidden.contains("track-mixes") { saved.hidden.append("track-mixes") }
            saved.save()
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "reco") }
    }
}
