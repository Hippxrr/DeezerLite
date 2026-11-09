import ImageIO
import UIKit

/// Pochettes choisies sur le téléphone pour une playlist, les titres aimés ou Flow : visibles seulement dans cette app,
/// rien n'est envoyé à Deezer. Une image carrée de 1000 px en JPEG par élément, dans Application Support
/// (pas dans Caches : iOS ne doit pas les effacer). Tout est supprimé à la déconnexion.
enum CustomCovers {
    /// Seuls les playlists, les titres aimés et Flow peuvent avoir une pochette perso.
    static func key(kind: String, id: UInt64) -> String? {
        switch kind {
        case "loved": "loved"
        case "flow": "flow"
        case "playlist": "playlist-\(id)"
        default: nil
        }
    }

    static func key(_ card: Card) -> String? { key(kind: card.kind, id: card.id) }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("custom-covers", isDirectory: true)
    }

    /// Recadre au centre en carré, réduit à 1000 px, enregistre ; renvoie l'adresse à afficher
    /// (avec un numéro de version : la nouvelle image remplace l'ancienne partout, sans cache périmé).
    static func save(_ data: Data, key: String) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000,
              ] as CFDictionary) else { return nil }
        // Déjà carrée et pas plus grande que 1000 px (image cadrée dans l'app) : enregistrée telle quelle,
        // sans seconde compression JPEG qui l'abîmerait un peu plus.
        if full.width == full.height, full.width <= 1000, CGImageSourceGetType(source) as String? == "public.jpeg" {
            return write(data, key: key)
        }
        let side = min(full.width, full.height)
        guard let square = full.cropping(to: CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2, width: side, height: side)) else { return nil }
        let size = CGFloat(min(side, 1000))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).jpegData(withCompressionQuality: 0.88) { _ in
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return write(jpeg, key: key)
    }

    private static func write(_ jpeg: Data, key: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(key).jpg")
            try jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return file.absoluteString + "?v=\(Int(Date().timeIntervalSince1970))"
        } catch {
            return nil
        }
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key).jpg"))
    }

    /// Déconnexion : plus aucune pochette perso sur le téléphone.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Adresses gardées recalculées à partir du dossier actuel : iOS peut déplacer le dossier de l'app lors d'une
    /// mise à jour, et l'ancienne adresse complète ne mènerait plus à l'image.
    static func load() -> [String: String] {
        let saved = (UserDefaults.standard.dictionary(forKey: "customCovers") as? [String: String]) ?? [:]
        return saved.mapValues { stored in
            guard let url = URL(string: stored) else { return stored }
            let version = url.query.map { "?" + $0 } ?? ""
            return directory.appendingPathComponent(url.lastPathComponent).absoluteString + version
        }
    }

    static func store(_ covers: [String: String]) {
        guard !covers.isEmpty else { UserDefaults.standard.removeObject(forKey: "customCovers"); return }
        UserDefaults.standard.set(covers, forKey: "customCovers")
    }
}
