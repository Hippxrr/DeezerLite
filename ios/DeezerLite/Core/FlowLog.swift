import Foundation

/// Journal de test (Réglages › Général › Test) : tout ce qui touche à Flow et à lecture / pause, pour trouver pourquoi
/// l'icône reste parfois sur lecture avec la barre d'onglets complète, au lieu de corriger au hasard. Rien n'est noté
/// tant qu'il est désactivé ; en mémoire seulement (2 000 lignes au plus), copié d'un appui.
@MainActor
enum FlowLog {
    static var on = UserDefaults.standard.bool(forKey: "flowLogOn")
    private static var lines: [String] = []
    private static let start = Date()
    /// Dernière icône dessinée par chaque bouton lecture / pause (true : pause affiché), comparée à l'état du lecteur.
    static var drawn: [String: Bool] = [:]

    static var count: Int { lines.count }
    static var text: String { lines.joined(separator: "\n") }

    static func note(_ s: @autoclosure () -> String) {
        guard on else { return }
        let t = String(format: "%7.3f", Date().timeIntervalSince(start))
        lines.append("\(t)  \(s())")
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    }

    static func clear() { lines.removeAll(); drawn.removeAll() }

    /// Contrôles automatiques après un appui : l'état affiché, celui du moteur et chaque icône dessinée doivent concorder.
    /// Un écart est marqué ⚠️ avec sa nature.
    static func checkLater(_ why: String, player: Player) {
        guard on else { return }
        for ms in [150, 400, 1000, 2500] {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(ms))
                check("\(why) +\(ms) ms", player: player)
            }
        }
    }

    static func check(_ label: String, player: Player) {
        guard on else { return }
        let shown = player.status.playing
        let engine = player.core?.status().playing
        var problems: [String] = []
        if let engine, engine != shown, !player.loading { problems.append("modèle=\(shown ? "lecture" : "pause") ≠ moteur=\(engine ? "lecture" : "pause")") }
        for (place, pause) in drawn.sorted(by: { $0.key < $1.key }) where pause != shown && !player.loading {
            problems.append("icône \(place) dessinée \(pause ? "⏸" : "▶︎") alors que modèle=\(shown ? "lecture" : "pause") (vue pas redessinée)")
        }
        let icons = drawn.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value ? "⏸" : "▶︎")" }.joined(separator: " ")
        let state = "modèle=\(shown ? "lecture" : "pause") moteur=\(engine.map { $0 ? "lecture" : "pause" } ?? "?") chargement=\(player.loading) icônes[\(icons)]"
        note(problems.isEmpty ? "✓ contrôle \(label) : \(state)" : "⚠️ contrôle \(label) : \(problems.joined(separator: " ; ")) | \(state)")
    }

    /// En-tête du journal copié : version, réglages qui comptent pour ce bug.
    static func header(player: Player) -> String {
        let d = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let full = d.object(forKey: "tabBarFull") as? Bool ?? true
        return """
        Deezer Lite \(version) — journal Flow / pause (\(lines.count) lignes)
        barre complète=\(full) (tenue=\(player.tabBarFullHeld.map { "\($0)" } ?? "non")) icône sans animation=\(d.bool(forKey: "playIconPlain")) \
        Flow=\(player.isFlow) titre=\(player.current.map { "\($0.id)" } ?? "aucun") mini=\(player.miniShown) grand lecteur=\(player.showFullPlayer)
        ---
        """
    }
}
