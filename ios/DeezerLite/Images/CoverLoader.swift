import CoreImage
import ImageIO
import UIKit

/// Pochettes : demandées à Deezer directement à la bonne taille, décodées à cette taille (ImageIO),
/// gardées dans un cache borné vidé au passage en arrière-plan. Jamais d'image 1000 x 1000 décodée pour une miniature.
final class CoverLoader: @unchecked Sendable {
    static let shared = CoverLoader()

    /// Tailles demandées au CDN de Deezer (pixels) : seulement ses tailles standard (celles de son API). Pour
    /// certaines pochettes (anciennes versions d'albums), il n'a pas les autres (64, 150 px…) et renvoie à la place son
    /// image vide, toute blanche. Peu de variantes, donc plus de réutilisation entre écrans (une ligne de liste et le
    /// mini-lecteur partagent la même image de 250 px).
    private static let sizes = [56, 120, 250, 500, 1000]
    /// Pochette pleine largeur du grand lecteur (réglage) : le CDN donne aussi 1500 x 1500, demandé seulement par elle
    /// (plus nette sur toute la largeur de l'écran).
    static let large = 1500
    /// Image vide du CDN (md5 d'un texte vide) : celle vers laquelle il redirige quand il n'a pas la taille demandée.
    private static let emptyPicture = "d41d8cd98f00b204e9800998ecf8427e"

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    /// Téléchargements en cours : deux vues qui veulent la même image n'en font qu'un.
    private var running: [String: Task<UIImage?, Never>] = [:]

    private init() {
        // 64 Mo d'images décodées (vidé si iOS manque de mémoire, et en arrière-plan). 16 Mo ne tenaient pas un écran
        // d'accueil (≈ 1 Mo par carte, 4 Mo par grande pochette) : au retour, les pochettes se rechargeaient.
        cache.totalCostLimit = 64 << 20
        backdrops.countLimit = 8 // fonds floutés (≈ 640 Ko chacun ; 1,4 Mo en pleine largeur) : le titre en cours et ses voisins
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 80 << 20) // rien en RAM, 80 Mo sur disque
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [cache, backdrops] _ in
                cache.removeAllObjects()
                backdrops.removeAllObjects() // fonds floutés : refaits au retour dans l'app
            }
        }
    }

    /// Place occupée par les pochettes enregistrées sur le téléphone (octets), affichée dans les Réglages.
    var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }

    /// Déconnexion : pochettes en mémoire et sur le disque effacées.
    func clear() {
        cache.removeAllObjects()
        colors.removeAllObjects()
        backdrops.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    static func bucket(_ pixels: Int) -> Int { pixels >= large ? large : sizes.first { $0 >= pixels } ?? sizes[sizes.count - 1] }

    private static func key(_ url: String, _ side: Int) -> NSString { "\(side)|\(url)" as NSString }

    /// Image déjà en mémoire à cette taille : lecture immédiate, sans attente (pour le premier affichage d'une vue).
    func cached(url: String, pixels: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, Self.bucket(pixels)))
    }

    /// N'importe quelle taille déjà en mémoire, la plus grande d'abord : affichée en attendant la bonne.
    func anyCached(url: String) -> UIImage? {
        for side in [Self.large] + Self.sizes.reversed() {
            if let hit = cache.object(forKey: Self.key(url, side)) { return hit }
        }
        return nil
    }

    /// `pixels` : côté en pixels réels (points x échelle de l'écran).
    func image(url: String, pixels: Int) async -> UIImage? {
        let side = Self.bucket(pixels)
        let key = Self.key(url, side)
        if let hit = cache.object(forKey: key) { return hit }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = running[key as String] { return existing }
            let task = Task.detached(priority: .userInitiated) { [session, cache] () -> UIImage? in
                let data: Data?
                if url.hasPrefix("/") {
                    data = try? Data(contentsOf: URL(fileURLWithPath: url))
                } else {
                    guard let u = URL(string: Self.sized(url, side)) else { return nil }
                    let answer = try? await session.data(from: u)
                    // Taille absente chez Deezer (redirigée vers l'image vide, blanche) : la grande, qui existe toujours,
                    // réduite ici à la taille voulue.
                    if let final = answer?.1.url?.absoluteString, final.contains(Self.emptyPicture), !url.contains(Self.emptyPicture),
                       let big = URL(string: Self.sized(url, side > 1000 ? 1000 : 500)) {
                        data = (try? await session.data(from: big))?.0
                    } else {
                        data = answer?.0
                    }
                }
                guard let data, let image = Self.downsample(data, side) else { return nil }
                let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
                cache.setObject(image, forKey: key, cost: cost)
                return image
            }
            running[key as String] = task
            return task
        }
        let image = await task.value
        // Retiré seulement si c'est encore ce téléchargement-là (un plus récent a pu le remplacer entre-temps).
        lock.withLock { if running[key as String] == task { running[key as String] = nil } }
        return image
    }

    private let colors = NSCache<NSString, UIColor>()

    /// Couleur dominante de la pochette, assombrie pour servir de fond. Calculée une fois par pochette
    /// sur une image de 8 x 8 pixels (quelques microsecondes), puis gardée en mémoire.
    func color(url: String) async -> UIColor? {
        if let hit = colors.object(forKey: url as NSString) { return hit }
        let small: UIImage?
        if let any = anyCached(url: url) { small = any } else { small = await image(url: url, pixels: 64) }
        guard let cg = small?.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return nil }
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2])
        }
        let n = CGFloat(px.count / 4 * 255)
        var hue: CGFloat = 0, sat: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(r) / n, green: CGFloat(g) / n, blue: CGFloat(b) / n, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bright, alpha: &alpha)
        // Ni trop sombre ni trop clair : le texte blanc reste lisible.
        let color = UIColor(hue: hue, saturation: min(sat * 1.15, 0.85), brightness: min(max(bright, 0.3), 0.55), alpha: 1)
        colors.setObject(color, forKey: url as NSString)
        return color
    }

    private let backdrops = NSCache<NSString, UIImage>()

    /// Contexte Core Image partagé (le créer coûte cher ; un seul pour toute l'app).
    private let blurContext = CIContext(options: [.cacheIntermediates: false])

    /// Fond du lecteur : la pochette en bonne qualité (500 px), réduite à 400 px puis floutée une seule fois, hors du
    /// thread principal. Le résultat est gardé : afficher ou animer le lecteur ne recalcule aucun flou.
    /// La grande pochette déjà en mémoire (celle de l'écran verrouillé) sert si elle est là : pas de second
    /// téléchargement du même titre en 500 px. `download: false` : seulement à partir de ce qui est en mémoire.
    func backdrop(url: String, download: Bool = true) async -> UIImage? {
        if let hit = backdrops.object(forKey: url as NSString) { return hit }
        let inMemory = anyCached(url: url).flatMap { ($0.cgImage?.width ?? 0) >= 400 ? $0 : nil }
        let picture: UIImage?
        if let inMemory { picture = inMemory } else if download { picture = await image(url: url, pixels: 500) } else { return nil }
        guard let source = picture?.cgImage else { return nil }
        let context = blurContext
        let blurred: UIImage? = await Task.detached(priority: .userInitiated) {
            let input = CIImage(cgImage: source)
            let scale = 400 / CGFloat(max(source.width, source.height, 1))
            let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Bords étendus avant le flou : pas de halo sombre sur les côtés, puis recadrage à la taille d'origine.
            let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
            guard let out = context.createCGImage(soft, from: small.extent) else { return nil }
            return UIImage(cgImage: out)
        }.value
        guard let blurred else { return nil }
        backdrops.setObject(blurred, forKey: url as NSString)
        return blurred
    }

    /// Fond de la pochette pleine largeur : le fond flouté en haut, aux mêmes proportions que la pochette nette posée
    /// dessus, puis les couleurs de son bas prolongées jusqu'en bas de l'écran (dégradé des mêmes couleurs). Fait une
    /// fois par titre, hors du thread principal. `tall` : hauteur de l'écran divisée par sa largeur.
    func bleedBackdrop(url: String, download: Bool, tall: CGFloat) async -> UIImage? {
        let key = "\(tall)|\(url)" as NSString
        if let hit = backdrops.object(forKey: key) { return hit }
        guard let square = await backdrop(url: url, download: download)?.cgImage else { return nil }
        let context = blurContext
        let extended: UIImage? = await Task.detached(priority: .userInitiated) {
            let input = CIImage(cgImage: square)
            let width = input.extent.width
            let canvas = CGRect(x: 0, y: 0, width: width, height: (width * tall).rounded())
            // Repère de Core Image : origine en bas. Le fond flouté est posé en haut ; sa dernière ligne est prolongée.
            let placed = input.transformed(by: CGAffineTransform(translationX: 0, y: canvas.height - input.extent.height))
            guard let out = context.createCGImage(placed.clampedToExtent().cropped(to: canvas), from: canvas) else { return nil }
            return UIImage(cgImage: out)
        }.value
        guard let extended else { return nil }
        backdrops.setObject(extended, forKey: key)
        return extended
    }

    /// Prépare des pochettes avant qu'elles ne soient affichées (titres suivants de la file).
    func prefetch(_ urls: [String], pixels: Int) {
        for url in urls where cached(url: url, pixels: pixels) == nil {
            Task.detached(priority: .utility) { _ = await self.image(url: url, pixels: pixels) }
        }
    }

    /// Le CDN Deezer sert la taille demandée dans l'URL (« 250x250-000000-80-0-0.jpg ») : moins de données, moins à décoder.
    private static func sized(_ url: String, _ side: Int) -> String {
        guard let r = url.range(of: #"/\d+x\d+-"#, options: .regularExpression) else { return url }
        return url.replacingCharacters(in: r, with: "/\(side)x\(side)-")
    }

    private static func downsample(_ data: Data, _ pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true, // décodé ici, en tâche de fond, pas au premier affichage
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}
