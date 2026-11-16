import Photos
import UIKit

extension Player {
    /// Réglages › « Appui long : enregistrer la pochette » (désactivé par défaut) : la pochette du titre en cours, en
    /// grand (1500 px), ajoutée à Photos. Accès demandé une fois, en ajout seulement : l'app ne voit pas la photothèque.
    func saveCurrentCoverToPhotos() {
        guard let track = current, track.id != 0, let url = cover(track) else {
            showToast(tr("Pas de pochette pour ce titre"), seconds: 3)
            return
        }
        Task {
            // En général déjà en mémoire : c'est celle affichée dans le grand lecteur.
            guard let image = await CoverLoader.shared.image(url: url, pixels: CoverLoader.large) else {
                showToast(tr("Pochette indisponible pour le moment"), seconds: 3)
                return
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                showToast(tr("Autorise l'ajout de photos dans Réglages › Deezer Lite › Photos"), seconds: 4)
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                showToast(tr("Pochette enregistrée dans Photos"))
            } catch {
                showToast(tr("Enregistrement impossible"), seconds: 3)
            }
        }
    }
}
