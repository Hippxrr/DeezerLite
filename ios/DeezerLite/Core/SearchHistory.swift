import Foundation

/// Historique de recherche, comme sur la version bureau : les recherches validées et ce qu'on a ouvert ou lancé
/// depuis les résultats (titre, album, artiste, playlist). 12 entrées au plus, gardées sur le téléphone.
struct HistoryEntry: Codable, Hashable {
    enum Kind: String, Codable { case query, track, card }

    var kind: Kind
    var query: String?
    // Titre : de quoi l'afficher et le relancer (sa fiche complète est redemandée au besoin).
    var trackId: Int64?
    var title: String?
    var subtitle: String?
    var coverUrl: String?
    var card: Pin?

    static func query(_ q: String) -> HistoryEntry { HistoryEntry(kind: .query, query: q) }

    static func track(_ t: Track) -> HistoryEntry {
        HistoryEntry(kind: .track, trackId: t.id, title: t.title, subtitle: t.artist, coverUrl: t.coverUrl)
    }

    static func card(_ c: Card) -> HistoryEntry { HistoryEntry(kind: .card, card: Pin(c)) }

    /// Même recherche, même titre ou même page : une seule entrée (la plus récente).
    var key: String {
        switch kind {
        case .query: "q:" + (query ?? "").lowercased()
        case .track: "t:\(trackId ?? 0)"
        case .card: "c:\(card?.kind ?? ""):\(card?.id ?? 0):\(card?.key ?? "")"
        }
    }

    var label: String {
        switch kind {
        case .query: query ?? ""
        case .track: title ?? ""
        case .card: card?.title ?? ""
        }
    }

    var detail: String {
        switch kind {
        case .query: ""
        case .track: tr("Titre · %@", subtitle ?? "")
        case .card:
            switch card?.kind {
            case "artist": tr("Artiste")
            case "album": card?.subtitle.isEmpty == false ? tr("Album · %@", card?.subtitle ?? "") : tr("Album")
            case "playlist": tr("Playlist")
            default: card?.subtitle ?? ""
            }
        }
    }

    static let limit = 12

    static func load() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: "search_history") else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [HistoryEntry]) {
        // Vide : la clé est retirée, rien ne reste sur le téléphone.
        guard !entries.isEmpty else { UserDefaults.standard.removeObject(forKey: "search_history"); return }
        if let data = try? JSONEncoder().encode(Array(entries.prefix(limit))) { UserDefaults.standard.set(data, forKey: "search_history") }
    }
}
