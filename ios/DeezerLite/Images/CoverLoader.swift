import CoreImage
import CoreImage.CIFilterBuiltins
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
    /// Adresses pour lesquelles Deezer n'a renvoyé que son image vide (pochette supprimée chez lui), sous `lock`.
    private var empty: Set<String> = []

    /// Pochette qui n'existe plus chez Deezer : son adresse ne montre que l'image vide (carré gris).
    func isEmptyPicture(_ url: String) -> Bool {
        url.contains(Self.emptyPicture) || lock.withLock { empty.contains(url) }
    }

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
        // Chargements en cours annulés : finis après la déconnexion, ils remettaient des pochettes de l'ancien compte dans
        // le cache (en mémoire et sur le disque).
        lock.withLock {
            running.values.forEach { $0.cancel() }
            running.removeAll()
        }
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
            let task = Task.detached(priority: .userInitiated) { [session, cache, self] () -> UIImage? in
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
                        let second = try? await session.data(from: big)
                        data = second?.0
                        // Vide aussi en grand : la pochette n'existe plus du tout chez Deezer. Retenu pour qu'un titre
                        // téléchargé montre son image enregistrée (voir `Player`, événement `.track`).
                        if second?.1.url?.absoluteString.contains(Self.emptyPicture) == true {
                            _ = self.lock.withLock { self.empty.insert(url) }
                        }
                    } else {
                        data = answer?.0
                    }
                }
                guard let data, !Task.isCancelled, let image = Self.downsample(data, side) else { return nil }
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

    /// Fond déjà fait (voir `backdrop` et `bleedBackdrop`), lu tout de suite : le lecteur s'ouvre avec son fond, sans
    /// passer par le noir le temps d'aller le chercher.
    func cachedBackdrop(url: String, saturation: CGFloat = 1, tall: CGFloat? = nil, inset: CGFloat = 0, zoom: CGFloat = 1,
                        classic: Bool = false) -> UIImage? {
        let key = tall.map { "\($0)|\(inset)|\(zoom)|\(classic)|\(url)" } ?? (saturation == 1 ? url : "\(saturation)|\(url)")
        return backdrops.object(forKey: key as NSString)
    }

    /// Fond du lecteur : la pochette en bonne qualité (500 px), réduite à 400 px puis floutée une seule fois, hors du
    /// thread principal. Le résultat est gardé : afficher ou animer le lecteur ne recalcule aucun flou.
    /// La grande pochette déjà en mémoire (celle de l'écran verrouillé) sert si elle est là : pas de second
    /// téléchargement du même titre en 500 px. `download: false` : seulement à partir de ce qui est en mémoire.
    /// `saturation` : appliquée ici, une fois (1 : aucune). Avant, le lecteur l'appliquait à chaque image de son
    /// ouverture, de sa fermeture et du glissement (filtre sur une image plein écran, deux pendant un fondu).
    func backdrop(url: String, download: Bool = true, saturation: CGFloat = 1) async -> UIImage? {
        let key = (saturation == 1 ? url : "\(saturation)|\(url)") as NSString
        if let hit = backdrops.object(forKey: key) { return hit }
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
            var soft = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
            if saturation != 1 {
                soft = soft.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            }
            guard let out = context.createCGImage(soft, from: small.extent) else { return nil }
            return UIImage(cgImage: out)
        }.value
        guard let blurred else { return nil }
        backdrops.setObject(blurred, forKey: key)
        return blurred
    }

    /// Fond de la pochette pleine largeur, posé sous la pochette nette (sous la barre d'état) : ses couleurs du haut
    /// prolongées derrière l'heure ; sous elle, son reflet, de plus en plus flou (en partant de presque rien), qui finit
    /// sur une seule couleur. Fait une fois par
    /// titre, hors du thread principal. `tall` : hauteur de l'écran / largeur ; `inset` : hauteur de la barre d'état / largeur ;
    /// `zoom` : hauteur de la pochette / largeur (plus haute que large, elle est centrée et coupée sur les côtés).
    /// `classic` : pochette entière ou moyenne (pas haute ni moyenne floue) : le flou d'avant, net sous la pochette.
    func bleedBackdrop(url: String, download: Bool, tall: CGFloat, inset: CGFloat, zoom: CGFloat = 1, classic: Bool = false) async -> UIImage? {
        let key = "\(tall)|\(inset)|\(zoom)|\(classic)|\(url)" as NSString
        if let hit = backdrops.object(forKey: key) { return hit }
        let inMemory = anyCached(url: url).flatMap { ($0.cgImage?.width ?? 0) >= 400 ? $0 : nil }
        let picture: UIImage?
        if let inMemory { picture = inMemory } else if download { picture = await image(url: url, pixels: 500) } else { return nil }
        guard let full = picture?.cgImage else { return nil }
        // Pochette pas carrée (MP3 importé, photo) : recadrée au centre comme la pochette affichée (remplissage), sinon le
        // fond posé sous elle ne coïncide pas et les deux images se chevauchent.
        let edge = min(full.width, full.height)
        let source = full.cropping(to: CGRect(x: (full.width - edge) / 2, y: (full.height - edge) / 2, width: edge, height: edge)) ?? full
        let context = blurContext
        let extended: UIImage? = await Task.detached(priority: .userInitiated) {
            let width: CGFloat = 400
            let scale = width * zoom / CGFloat(max(source.width, source.height, 1))
            let side = (CGFloat(source.height) * scale).rounded()
            // Bords prolongés avant la réduction : sinon ses lignes du bord sortent à moitié transparentes, et le reflet,
            // collé au bord net de la pochette, y faisait un trait sombre.
            let input = CIImage(cgImage: source).clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(source.width) * scale, height: side))
                .transformed(by: CGAffineTransform(translationX: -(width * zoom - width) / 2, y: 0))
            let canvas = CGRect(x: 0, y: 0, width: width, height: (width * tall).rounded())
            // Repère de Core Image : origine en bas. La pochette est posée sous la barre d'état.
            let gap = (width * inset).rounded()
            let bottom = canvas.height - gap - side // bas de la pochette ; en dessous, `bottom` pixels de fond
            let placed = input.transformed(by: CGAffineTransform(translationX: 0, y: bottom))
            // Sous la pochette : son reflet (bas de la pochette retourné). À la jonction, mêmes pixels des deux côtés : aucune
            // coupure. Il y a ainsi une vraie image à flouter de plus en plus ; des couleurs prolongées, lisses dès le départ,
            // donnaient un flou « d'un coup », sans dégradé visible. Au-delà du reflet, sa dernière ligne (déjà très floue).
            let mirrored = placed.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * bottom))
            let belowArea = CGRect(x: -width, y: -canvas.height, width: width * 3, height: canvas.height + bottom)
            // Au-dessus (derrière l'heure) : aussi un reflet, du haut de la pochette. Avant, sa première ligne était étirée vers
            // le haut : des traînées, et une limite visible quand cette ligne ne ressemblait pas à la suite (bord, cadre).
            let top = bottom + side
            let mirroredTop = placed.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * top))
            let aboveArea = CGRect(x: -width, y: top, width: width * 3, height: canvas.height)
            // Seule une bande au ras de la pochette est reflétée, puis sa dernière ligne est prolongée : un texte près du
            // bord ne se retrouve plus écrit à l'envers sur toute la hauteur du reflet.
            let band = (side * 10 / 920).rounded() // ≈ 10 px à l'écran
            let topBand = max((side * 5 / 920).rounded(), 1) // ≈ 5 px à l'écran // en haut, encore plus fin (derrière l'heure)
            let extendedCover = mirroredTop.cropped(to: CGRect(x: 0, y: top, width: width, height: topBand))
                .clampedToExtent().cropped(to: aboveArea)
                .composited(over: mirrored.cropped(to: CGRect(x: 0, y: bottom - band, width: width, height: band))
                    .clampedToExtent().cropped(to: belowArea))
                .composited(over: placed.clampedToExtent())
            // Force du flou, ligne par ligne (0 : net ; 1 : rayon maximal). Derrière l'heure, léger (le reflet du haut ressemble
            // au début de la pochette : plus de limite visible, avant il était aussi flou que le fond habituel) ; nul sous la
            // pochette (cachée ou en train de s'effacer), à peine au bas de celle-ci ; puis sous elle, il part de presque rien
            // et monte doucement sur les trois quarts de la hauteur restante (avant : la moitié, plus vite au départ, le flou
            // arrivait « d'un coup »).
            let blurred: CGFloat = 0.3 // sous le bas fondu de la pochette, et au départ de son reflet
            let base: CGFloat = 0.15 // 13 % avant : les traînées des hauts très chargés (fourrure, capuche) se voyaient un peu plus
            func eased(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
            func amount(_ row: CGFloat) -> CGFloat { // `row` : depuis le haut de l'écran
                if row < gap { return base }
                // Pochette entière : le flou d'avant. Net sous le milieu de la pochette, à peine flou à son bas, puis un reflet
                // qui part de presque rien. Le flou partout (plus bas) allait avec la pochette haute : sous la pochette entière,
                // son reflet paraissait trop flou d'un coup.
                if classic {
                    if row < gap + side * 0.1 { return base * (1 - eased((row - gap) / (side * 0.1))) }
                    if row < gap + side * 0.7 { return 0 }
                    if row < gap + side { return 0.04 * pow((row - gap - side * 0.7) / (side * 0.3), 2) }
                    return 0.04 + 0.96 * pow(min((row - gap - side) / (bottom * 0.75), 1), 1.8)
                }
                // Sous la pochette : flou partout (caché tant qu'elle est opaque). Elle se fond dans un flou d'elle-même, et une
                // pochette pas encore chargée pendant des glissements rapides laisse voir des couleurs floues, plus l'ancienne
                // pochette nette. En haut, aussi léger que derrière l'heure (plus fort, le fondu du haut faisait une démarcation) ;
                // plus fort sous le fondu du bas (à partir de 70 %).
                if row < gap + side { return base + (blurred - base) * eased((row - gap - side * 0.7) / (side * 0.08)) }
                return blurred + (1 - blurred) * pow(min((row - gap - side) / (bottom * 0.75), 1), 1.8)
            }
            let rows = Int(canvas.height)
            let column = (0..<rows).map { UInt8((amount(CGFloat($0)) * 255).rounded()) }
            guard let provider = CGDataProvider(data: Data(column) as CFData),
                  let strength = CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            // Valeurs prises telles quelles (sans gestion des couleurs, qui les aurait assombries).
            let mask = CIImage(cgImage: strength, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(scaleX: width, y: 1)).clampedToExtent()
            // Sous la pochette (dessous = vers 0 en Core Image), en courbe douce : de `from` (rien) à `to` (tout).
            func ramp(_ from: CGFloat, _ to: CGFloat) -> CIImage? {
                let g = CIFilter.smoothLinearGradient()
                g.point0 = CGPoint(x: 0, y: bottom - from * bottom)
                g.point1 = CGPoint(x: 0, y: bottom - to * bottom)
                g.color0 = .black
                g.color1 = .white
                return g.outputImage
            }
            // Flou progressif sur la pochette et son reflet.
            let blur = CIFilter.maskedVariableBlur()
            blur.inputImage = extendedCover
            blur.mask = mask
            blur.radius = 110
            // Puis une seule couleur : la moyenne du bas de la pochette.
            let average = CIFilter.areaAverage()
            average.inputImage = placed
            average.extent = CGRect(x: 0, y: bottom, width: width, height: side * 0.35)
            let mix = CIFilter.blendWithMask()
            mix.inputImage = average.outputImage?.clampedToExtent()
            mix.backgroundImage = blur.outputImage
            mix.maskImage = ramp(0.1, 0.9) // la couleur unique arrive un peu plus tard : le reflet reste visible plus longtemps
            guard let smooth = mix.outputImage?.cropped(to: canvas),
                  let out = context.createCGImage(smooth, from: canvas) else { return nil }
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
