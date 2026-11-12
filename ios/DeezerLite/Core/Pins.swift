import Foundation

/// Playlist, album, artiste ou mix épinglé sur l'accueil (gardé sur le téléphone).
struct Pin: Codable, Hashable {
    var kind: String
    var id: UInt64
    var title: String
    var subtitle: String
    var coverUrl: String?
    var key: String

    init(_ card: Card) {
        kind = card.kind
        id = card.id
        title = card.title
        subtitle = card.subtitle
        coverUrl = card.coverUrl
        key = card.key
    }

    var card: Card { Card(kind: kind, id: id, title: title, subtitle: subtitle, coverUrl: coverUrl, owned: false, key: key) }

    func matches(_ card: Card) -> Bool { card.kind == kind && card.id == id && card.key == key }

    static func load() -> [Pin] {
        guard let data = UserDefaults.standard.data(forKey: ProfileData.key("pins")) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }

    static func save(_ pins: [Pin]) {
        let key = ProfileData.key("pins") // propre au profil ouvert (compte Famille)
        guard !pins.isEmpty else { UserDefaults.standard.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: key) }
    }
}
