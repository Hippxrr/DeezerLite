import AVFoundation
import Observation
import UIKit

/// TEMPORAIRE (test AirPods, à retirer après) : journal de ce qu'iOS envoie à l'app (commandes, changements de sortie,
/// coupures), pour savoir pourquoi le retrait d'un seul AirPod ne met pas en pause. Affiché dans Réglages › Son.
@MainActor @Observable
final class AirPodsDiag {
    static let shared = AirPodsDiag()
    /// Interrupteur du test : session audio sans le mode « audio long » (`.longFormAudio`), appliqué au lancement.
    nonisolated static let plainPolicyKey = "diagPlainPolicy"
    nonisolated static var plainPolicy: Bool { UserDefaults.standard.bool(forKey: plainPolicyKey) }

    private(set) var lines: [String] = []
    @ObservationIgnored private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: String) {
        lines.insert("\(clock.string(from: Date()))  \(text)", at: 0)
        if lines.count > 80 { lines.removeLast() }
    }

    func clear() { lines = [] }

    /// Journal copié, pour le coller dans un message.
    func copy() { UIPasteboard.general.string = lines.reversed().joined(separator: "\n") }

    /// Depuis n'importe quel thread.
    nonisolated static func note(_ text: String) {
        Task { @MainActor in shared.log(text) }
    }

    /// Sorties audio lisibles : type et nom (ex. « BluetoothA2DPOutput AirPods Pro »).
    nonisolated static func describe(_ outputs: [AVAudioSessionPortDescription]) -> String {
        outputs.isEmpty ? "aucune" : outputs.map { "\($0.portType.rawValue) \($0.portName)" }.joined(separator: ", ")
    }
}
