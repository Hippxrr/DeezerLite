import Foundation

/// Égaliseur 5 bandes du moteur (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz, de -12 à +12 dB), présenté comme celui de
/// Deezer : un interrupteur, des préréglages qu'on fait défiler, cinq curseurs. « Désactivé » : son d'origine, sans aucun
/// calcul. Toucher un curseur d'un préréglage le recopie dans « Personnalisé ». Un limiteur doux évite la saturation.
enum EqPreset: String, CaseIterable, Identifiable {
    case off, bassBoost, bassCut, trebleBoost, trebleCut, vocal, acoustic, classical, dance, electronic, hipHop, jazz, pop, rock, custom

    var id: String { rawValue }

    /// Réglage enregistré, y compris ceux de l'ancien égaliseur 3 bandes (repris par leur équivalent).
    init?(saved: String) {
        switch saved {
        case "bass": self = .bassBoost
        case "clarity": self = .trebleBoost
        case "party": self = .dance
        default: self.init(rawValue: saved)
        }
    }

    var name: String {
        switch self {
        case .off: tr("Désactivé")
        case .bassBoost: tr("Amplificateur de basses")
        case .bassCut: tr("Réducteur de basses")
        case .trebleBoost: tr("Amplificateur d'aigus")
        case .trebleCut: tr("Réducteur d'aigus")
        case .vocal: tr("Voix")
        case .acoustic: tr("Acoustique")
        case .classical: tr("Classique")
        case .dance: "Dance"
        case .electronic: tr("Électro")
        case .hipHop: "Hip-hop"
        case .jazz: "Jazz"
        case .pop: "Pop"
        case .rock: "Rock"
        case .custom: tr("Personnalisé")
        }
    }

    var icon: String {
        switch self {
        case .off: "waveform.slash"
        case .bassBoost: "speaker.wave.3"
        case .bassCut: "speaker.wave.1"
        case .trebleBoost: "sparkles"
        case .trebleCut: "sparkle"
        case .vocal: "mic"
        case .acoustic: "guitars"
        case .classical: "pianokeys"
        case .dance: "figure.dance"
        case .electronic: "bolt"
        case .hipHop: "headphones"
        case .jazz: "music.quarternote.3"
        case .pop: "star"
        case .rock: "flame"
        case .custom: "slider.horizontal.3"
        }
    }

    /// Gain de chaque bande en dB ; `nil` pour « Personnalisé » (réglages de l'utilisateur).
    var gains: [Double]? {
        switch self {
        case .off: [0, 0, 0, 0, 0]
        case .bassBoost: [6, 4, 2, 0, 0]
        case .bassCut: [-6, -4, -2, 0, 0]
        case .trebleBoost: [0, 0, 2, 4, 6]
        case .trebleCut: [0, 0, -2, -4, -6]
        case .vocal: [-2, -1, 3, 4, 2]
        case .acoustic: [4, 2, 1, 2, 3]
        case .classical: [4, 2, -1, 2, 4]
        case .dance: [5, 3, 0, 2, 3]
        case .electronic: [5, 2, -1, 2, 5]
        case .hipHop: [5, 4, 0, 1, 3]
        case .jazz: [3, 2, -1, 2, 3]
        case .pop: [-1, 2, 4, 2, -1]
        case .rock: [5, 2, -2, 2, 5]
        case .custom: nil
        }
    }

    /// Préréglages qu'on fait défiler avec les flèches (ni « Désactivé » ni « Personnalisé »).
    static let named: [EqPreset] = allCases.filter { $0 != .off && $0 != .custom }

    static let bands = ["60", "230", "910", "3,6k", "14k"]

    /// Réglage perso de l'ancien égaliseur 3 bandes (graves, médiums, aigus) réparti sur les 5 bandes.
    static func fromThreeBands(_ g: [Double]) -> [Double] {
        [g[0], (g[0] + g[1]) / 2, g[1], (g[1] + g[2]) / 2, g[2]]
    }
}
