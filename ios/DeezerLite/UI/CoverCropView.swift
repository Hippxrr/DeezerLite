import ImageIO
import SwiftUI

/// Photo choisie pour une pochette perso, en attente de cadrage.
struct CoverCrop: Identifiable {
    let id = UUID()
    let card: Card
    let image: UIImage
}

/// Cadrage d'une pochette perso : on pince pour zoomer, on glisse pour placer l'image dans le carré ;
/// l'aperçu montre exactement ce qui sera enregistré.
struct CoverCropView: View {
    let image: UIImage
    /// Image carrée finale (JPEG).
    let onDone: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let maxScale: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let side = max(1, min(geo.size.width - 32, geo.size.height - 120))
                let base = fill(side)
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: base.width * scale, height: base.height * scale)
                        .offset(offset)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            SimultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { v in
                                        scale = min(max(lastScale * v.magnification, 1), Self.maxScale)
                                        offset = clamp(offset, side: side, base: base)
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        lastOffset = offset
                                    },
                                DragGesture()
                                    .onChanged { v in
                                        offset = clamp(CGSize(width: lastOffset.width + v.translation.width,
                                                              height: lastOffset.height + v.translation.height), side: side, base: base)
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            )
                        )
                    Text(tr("Pince pour zoomer, glisse pour cadrer."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(tr("Annuler")) { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(tr("Choisir")) {
                            if let data = render(side: side, base: base) { onDone(data) }
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Cadrer la pochette"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    /// Taille de l'image qui remplit tout juste le carré (zoom 1).
    private func fill(_ side: CGFloat) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let k = side / min(w, h)
        return CGSize(width: w * k, height: h * k)
    }

    /// L'image couvre toujours tout le carré : pas de bord vide.
    private func clamp(_ o: CGSize, side: CGFloat, base: CGSize) -> CGSize {
        let maxX = max(0, (base.width * scale - side) / 2)
        let maxY = max(0, (base.height * scale - side) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    /// Ce qui est visible dans le carré, en 1000 x 1000.
    private func render(side: CGFloat, base: CGSize) -> Data? {
        let out: CGFloat = 1000
        let k = out / side
        let drawn = CGSize(width: base.width * scale * k, height: base.height * scale * k)
        let origin = CGPoint(x: (out - drawn.width) / 2 + offset.width * k, y: (out - drawn.height) / 2 + offset.height * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).jpegData(withCompressionQuality: 0.9) { _ in
            image.draw(in: CGRect(origin: origin, size: drawn))
        }
    }

    /// Photo lue à 2000 px au plus (une photo de 48 Mpx décodée en entier prendrait des centaines de Mo).
    static func load(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
