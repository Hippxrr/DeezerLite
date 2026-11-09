import Foundation
import Observation

/// Langue de l'app, choisie dans Réglages > Général. Les vues lisent leurs textes avec `tr`, qui passe par ce magasin
/// observé par SwiftUI : changer de langue met à jour ce qui est affiché, sans relancer l'app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case fr, en, es

    var id: String { rawValue }

    /// Nom de la langue, toujours dans cette langue.
    var title: String {
        switch self {
        case .fr: "Français"
        case .en: "English"
        case .es: "Español"
        }
    }
}

@Observable
final class LanguageStore {
    static let shared = LanguageStore()

    private(set) var current: AppLanguage

    /// Dates et mois dans la langue choisie.
    var locale: Locale { Locale(identifier: current.rawValue) }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "language").flatMap(AppLanguage.init(rawValue:))
        // Premier lancement : celle de l'iPhone si l'app la connaît, sinon le français.
        let system = Locale.preferredLanguages.first.flatMap { AppLanguage(rawValue: String($0.prefix(2))) }
        current = saved ?? system ?? .fr
    }

    func select(_ language: AppLanguage) {
        current = language
        UserDefaults.standard.set(language.rawValue, forKey: "language")
    }
}

/// Texte dans la langue choisie ; `french` en est la clé (voir `Translations`).
func tr(_ french: String) -> String {
    let language = LanguageStore.shared.current
    guard language != .fr, let text = Translations.table[french] else { return french }
    return language == .en ? text.en : text.es
}

/// Texte à variables : `%@` y marque leur place, dans chaque langue.
func tr(_ french: String, _ values: String...) -> String {
    String(format: tr(french), arguments: values.map { $0 as NSString })
}
