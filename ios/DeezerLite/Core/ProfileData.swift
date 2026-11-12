import Foundation

/// Données gardées à part pour chaque profil d'un compte Famille : historique de recherche, éléments épinglés, dernière
/// écoute. Un enfant ne voit plus les recherches ni les playlists épinglées du parent (ni l'inverse).
enum ProfileData {
    private static let bases = ["search_history", "pins", "lastSession"]

    /// Clé du profil ouvert. Compte simple (aucun profil choisi) : la clé de base, comme avant.
    static func key(_ base: String) -> String {
        let defaults = UserDefaults.standard
        guard let id = (defaults.object(forKey: "profileId") as? NSNumber)?.uint64Value else { return base }
        let key = "\(base).\(id)"
        // Données d'avant cette séparation : elles vont au profil ouvert à ce moment-là (celui qui s'en servait).
        if defaults.object(forKey: key) == nil, let old = defaults.object(forKey: base) {
            defaults.set(old, forKey: key)
            defaults.removeObject(forKey: base)
        }
        return key
    }

    /// Déconnexion : rien d'aucun profil ne reste sur le téléphone.
    static func clearAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where bases.contains(where: { key == $0 || key.hasPrefix($0 + ".") }) {
            defaults.removeObject(forKey: key)
        }
    }
}
