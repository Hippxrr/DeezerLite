import Foundation

/// Dernière écoute, gardée sur le téléphone au passage en arrière-plan : si iOS ferme l'app, elle se rouvre sur le même
/// titre, la même file et la même position (en pause ; un appui sur lecture reprend). Effacée à la déconnexion.
struct LastSession: Codable {
    struct SavedTrack: Codable {
        var id: Int64
        var title: String
        var artist: String
        var album: String
        var durationS: UInt64
        var coverUrl: String?
        var artistId: UInt64
        var albumId: UInt64

        init(_ t: Track) {
            id = t.id
            title = t.title
            artist = t.artist
            album = t.album
            durationS = t.durationS
            coverUrl = t.coverUrl
            artistId = t.artistId
            albumId = t.albumId
        }

        var track: Track {
            Track(id: id, title: title, artist: artist, album: album, durationS: durationS, coverUrl: coverUrl,
                  quality: nil, artistId: artistId, albumId: albumId, addedAt: nil, releaseDate: nil, artists: [])
        }
    }

    var tracks: [SavedTrack]
    var index: Int
    var positionMs: UInt64

    /// Autour du titre en cours : 10 avant, 90 après (une file de milliers de titres resterait légère à garder).
    init?(queue: [Track], index: Int, positionMs: UInt64) {
        guard queue.indices.contains(index) else { return nil }
        let from = max(0, index - 10)
        let to = min(queue.count, index + 90)
        tracks = queue[from..<to].map { SavedTrack($0) }
        self.index = index - from
        self.positionMs = positionMs
    }

    private static let key = "lastSession"

    static func load() -> LastSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastSession.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
