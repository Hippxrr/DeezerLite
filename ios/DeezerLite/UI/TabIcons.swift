import UIKit

/// Icônes de la barre d'onglets, dessinées par l'app (carré de 24 x 24, mis à l'échelle). En mode modèle : la barre leur
/// donne elle-même sa couleur, sélectionnée ou non.
enum TabIcons {
    /// Maison au toit arrondi, porte découpée dans le bas.
    static let home = draw { c in
        c.addPath(outline([
            (12, 1.6, 2.2), (21.4, 10.2, 2.4), (21.4, 22.4, 2.8),
            (14.8, 22.4, 0.9), (14.8, 14.6, 1), (9.2, 14.6, 1), (9.2, 22.4, 0.9),
            (2.6, 22.4, 2.8), (2.6, 10.2, 2.4),
        ]))
        c.fillPath()
    }

    /// Carré à la note de musique découpée, deux barres empilées au-dessus.
    static let library = draw { c in
        c.addPath(CGPath(roundedRect: CGRect(x: 9, y: 0.6, width: 6, height: 1.7), cornerWidth: 0.85, cornerHeight: 0.85, transform: nil))
        c.addPath(CGPath(roundedRect: CGRect(x: 6.5, y: 3.5, width: 11, height: 1.9), cornerWidth: 0.95, cornerHeight: 0.95, transform: nil))
        c.addPath(CGPath(roundedRect: CGRect(x: 3, y: 6.6, width: 18, height: 17), cornerWidth: 4.4, cornerHeight: 4.4, transform: nil))
        c.fillPath()
        // Note : ce qui est dessiné ici devient transparent.
        c.setBlendMode(.clear)
        // Centrée à l'œil dans le carré : un peu à gauche du centre exact, le côté droit de la note étant plus lourd.
        c.addEllipse(in: CGRect(x: 6.65, y: 16.75, width: 4.2, height: 3.5))
        c.addEllipse(in: CGRect(x: 12.35, y: 15.65, width: 4.2, height: 3.5))
        c.addRect(CGRect(x: 9.45, y: 11.15, width: 1.4, height: 7.4))
        c.addRect(CGRect(x: 15.15, y: 10.05, width: 1.4, height: 7.4))
        c.move(to: CGPoint(x: 9.45, y: 11.15))
        c.addLine(to: CGPoint(x: 16.55, y: 9.75))
        c.addLine(to: CGPoint(x: 16.55, y: 11.75))
        c.addLine(to: CGPoint(x: 9.45, y: 13.15))
        c.closePath()
        c.fillPath()
    }

    private static func draw(_ body: (CGContext) -> Void) -> UIImage {
        let side: CGFloat = 27
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { renderer in
            let c = renderer.cgContext
            c.scaleBy(x: side / 24, y: side / 24)
            c.setFillColor(UIColor.black.cgColor)
            body(c)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Contour fermé passant par ces points (x, y, rayon de l'arrondi).
    private static func outline(_ points: [(CGFloat, CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        let first = points[0], last = points[points.count - 1]
        path.move(to: CGPoint(x: (first.0 + last.0) / 2, y: (first.1 + last.1) / 2))
        for (i, p) in points.enumerated() {
            let next = points[(i + 1) % points.count]
            path.addArc(tangent1End: CGPoint(x: p.0, y: p.1), tangent2End: CGPoint(x: next.0, y: next.1), radius: p.2)
        }
        path.closeSubpath()
        return path
    }
}
