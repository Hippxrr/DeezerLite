import Observation
import UIKit

/// TEMPORAIRE (test AirPods, à retirer après) : journal de ce que voient les capteurs des AirPods (quel écouteur
/// fournit le mouvement, coupures du flux, état « connecté »), pour trouver comment détecter le retrait de l'autre
/// AirPod. Affiché dans Réglages › Son.
@MainActor @Observable
final class AirPodsDiag {
    static let shared = AirPodsDiag()

    private(set) var lines: [String] = []
    @ObservationIgnored private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: String) {
        lines.insert("\(clock.string(from: Date()))  \(text)", at: 0)
        if lines.count > 150 { lines.removeLast() }
    }

    func clear() { lines = [] }

    /// Journal copié, pour le coller dans un message.
    func copy() { UIPasteboard.general.string = lines.reversed().joined(separator: "\n") }
}
