import Foundation
import Security

/// Le cœur range l'ARL dans le trousseau avec le réglage par défaut d'iOS : lisible seulement iPhone déverrouillé.
/// CarPlay peut lancer l'app téléphone verrouillé (dans la poche) : l'ARL doit alors rester lisible.
/// On passe l'élément en « après le premier déverrouillage, sur cet appareil seulement » (comme les fichiers de l'app).
/// Possible seulement iPhone déverrouillé : refait à chaque lancement et après chaque connexion, sans effet s'il est déjà bon.
enum KeychainAccess {
    /// Efface la session Deezer du trousseau. iOS garde le trousseau quand l'app est supprimée : sans ça, une
    /// réinstallation retrouvait l'ancienne session et reconnectait le compte tout seul.
    static func forgetSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "deezer-lite",
            kSecAttrAccount as String: "arl",
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Trousseau (session oubliée) : \(status)")
        }
    }

    static func allowWhileLocked() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "deezer-lite",
            kSecAttrAccount as String: "arl",
        ]
        let change: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound && status != errSecInteractionNotAllowed {
            print("Trousseau (accès verrouillé) : \(status)")
        }
    }
}
