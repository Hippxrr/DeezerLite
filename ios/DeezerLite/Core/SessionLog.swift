import CryptoKit
import Foundation
import MetricKit
import os
import Security
import SwiftUI
import UIKit

/// Journal de diagnostic (temporaire : pour trouver pourquoi un iPhone perd sa session, et pourquoi l'accueil reste parfois
/// noir). Quelques lignes aux moments clés (lancement, passages en arrière-plan, session, connexion, accueil, lecteur plein
/// écran, erreurs, plantages relevés par iOS), jamais pendant la lecture : écrites hors du fil de l'interface, dans un petit
/// fichier gardé d'un lancement à l'autre (128 Ko au plus). Ni e-mail ni ARL : seulement une empreinte courte de l'ARL,
/// pour voir s'il a changé. Copié (avec l'état de l'app à ce moment-là) par un bouton, ou en secouant l'iPhone.
enum SessionLog {
    private static let queue = DispatchQueue(label: "session-log", qos: .utility)
    /// À part du dossier de l'app (`deezer-lite`) : son absence sert à repérer une nouvelle installation.
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("session-log.txt")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM HH:mm:ss"
        return f
    }()
    /// Vrai tant que l'app est à l'écran : encore vrai au lancement suivant = arrêt brutal (plantage, blocage).
    private static let runningKey = "diagnosticRunning"
    /// Lecteur, pour l'état copié avec le journal (posé au lancement).
    @MainActor static weak var player: Player?
    /// Dernière place connue à l'écran des vues suivies (voir `DiagnosticProbe`), lue seulement à la copie.
    @MainActor private static var places: [String: CGRect] = [:]
    /// États complets déjà notés par le contrôle de l'écran depuis le lancement.
    @MainActor private static var fullStates = 0

    /// Une ligne datée. `detail` est calculé hors du fil de l'interface.
    static func note(_ detail: @escaping @Sendable () -> String) {
        let at = Date()
        queue.async { write("\(stamp.string(from: at))  \(detail())\n") }
    }

    static func note(_ text: String) { note { text } }

    /// Bloc complet au lancement : app, iOS, appareil, écran, réglages, signature, conteneur, dossier de l'app, trousseau.
    @MainActor static func launch(folderExisted: Bool, sessionSaved: Bool) {
        let state = UIApplication.shared.applicationState
        let protected = UIApplication.shared.isProtectedDataAvailable
        let system = UIDevice.current.systemVersion
        let size = UIScreen.main.bounds.size
        let defaults = UserDefaults.standard
        let settings = "barre de l'app \((defaults.object(forKey: "tabBarFull") as? Bool ?? true) ? "oui" : "non")"
            + " · pochette pleine largeur \(defaults.bool(forKey: "fullBleedCover") ? "oui" : "non")"
            + " · apparence \(ThemeStore.shared.appearance.rawValue)"
        note {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
            let up = Int(ProcessInfo.processInfo.systemUptime / 60)
            let launched = state == .background ? "en arrière-plan" : state == .inactive ? "inactive" : "à l'écran"
            return """
            ===== LANCEMENT : app \(version) · iOS \(system) · \(model()) · écran \(Int(size.width))×\(Int(size.height))
              lancée \(launched) · données protégées \(protected ? "lisibles" : "verrouillées") · iPhone allumé depuis \(up / 60) h \(up % 60) min
              \(memory()) · réglages : \(settings)
              \(signing())
              conteneur \(URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent)
              dossier de l'app \(folderExisted ? "présent" : "ABSENT (nouvelle installation : session effacée du trousseau)") · session notée \(sessionSaved ? "oui" : "non")
              \(keychain())
            """
        }
    }

    /// Branché au lancement : passages en arrière-plan, mémoire, verrouillage, arrêt brutal du lancement précédent,
    /// plantages et blocages relevés par iOS, contrôle de l'écran au retour dans l'app.
    @MainActor static func watch(_ player: Player) {
        self.player = player
        if UserDefaults.standard.bool(forKey: runningKey) {
            note("⚠️ le lancement précédent s'est arrêté d'un coup à l'écran (plantage, blocage, ou fermé par iOS)")
        }
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app active"),
            (UIApplication.willResignActiveNotification, "app inactive"),
            (UIApplication.didEnterBackgroundNotification, "app en arrière-plan"),
            (UIApplication.willEnterForegroundNotification, "app de retour au premier plan"),
            (UIApplication.didReceiveMemoryWarningNotification, "⚠️ mémoire presque pleine"),
            (UIApplication.willTerminateNotification, "app fermée"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "iPhone verrouillé (données protégées fermées)"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "données protégées lisibles"),
            (UIScene.willConnectNotification, "fenêtre de l'app créée"),
            (UIScene.didDisconnectNotification, "fenêtre de l'app retirée"),
        ]
        for (name, label) in events {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    note { "\(label) · \(memory())" }
                    switch name {
                    case UIApplication.didBecomeActiveNotification:
                        UserDefaults.standard.set(true, forKey: runningKey)
                        checkScreenSoon("retour dans l'app")
                    case UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification:
                        UserDefaults.standard.set(false, forKey: runningKey)
                    default: break
                    }
                }
            }
        }
        if UIApplication.shared.applicationState != .background { UserDefaults.standard.set(true, forKey: runningKey) }
        MXMetricManager.shared.add(CrashReceiver.shared)
    }

    /// Place d'une vue suivie : gardée pour la copie, notée seulement quand sa taille change.
    @MainActor static func place(_ name: String, _ frame: CGRect) {
        let old = places[name]
        places[name] = frame
        if old.map({ Int($0.width) != Int(frame.width) || Int($0.height) != Int(frame.height) }) ?? true {
            note("\(name) : place \(rect(frame))")
        }
    }

    /// Contrôle de l'écran un peu après l'ouverture : un écran presque d'une seule couleur (l'écran noir) est noté, avec
    /// l'état complet de l'app à ce moment-là.
    @MainActor static func checkScreenSoon(_ reason: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard UIApplication.shared.applicationState == .active, let window = keyWindow() else { return }
            let (share, color) = sameColor(window)
            note("contrôle de l'écran (\(reason)) : \(share) % d'une seule couleur (\(color))")
            // État complet 3 fois au plus par lancement : une page presque vide (recherche) le noterait à chaque retour.
            if share >= 95, fullStates < 3 {
                fullStates += 1
                note("⚠️ ÉCRAN PRESQUE UNI, état à ce moment-là :\n\(state())")
            }
        }
    }

    /// Copie le journal, avec l'état actuel de l'app en tête (bouton, ou iPhone secoué).
    @MainActor static func copy() {
        let colors = keyWindow().map { sameColor($0) }
        let colorLine = colors.map { "  écran : \($0.0) % d'une seule couleur (\($0.1))\n" } ?? ""
        UIPasteboard.general.string = "===== COPIÉ LE \(stamp.string(from: Date()))\n\(colorLine)\(state())\n\n\(text())"
        player?.showToast(tr("Journal copié"))
    }

    /// État de l'ARL dans le trousseau : présent (groupe, accès, dates, empreinte) ou code d'erreur.
    static func keychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "deezer-lite",
            kSecAttrAccount as String: "arl",
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let item = out as? [String: Any] else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "trousseau : pas d'ARL lisible (code \(status) \(reason))"
        }
        let group = item[kSecAttrAccessGroup as String] as? String ?? "?"
        let access = item[kSecAttrAccessible as String] as? String ?? "?"
        let created = (item[kSecAttrCreationDate as String] as? Date).map(stamp.string(from:)) ?? "?"
        let modified = (item[kSecAttrModificationDate as String] as? Date).map(stamp.string(from:)) ?? "?"
        let fp = (item[kSecValueData as String] as? Data).map(fingerprint) ?? "?"
        return "trousseau : ARL présent, empreinte \(fp), groupe \(group), accès \(access), créé \(created), modifié \(modified)"
    }

    /// Empreinte courte (8 caractères) : montre si l'ARL a changé, sans rien révéler de lui.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ text: String) -> String { fingerprint(Data(text.utf8)) }

    /// Texte complet, pour le copier.
    static func text() -> String {
        queue.sync { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }

    /// Mémoire prise par l'app, et ce qu'iOS lui laisse encore avant de la fermer.
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let used = result == KERN_SUCCESS ? "\(info.phys_footprint >> 20) Mo" : "?"
        return "mémoire \(used) (encore \(os_proc_available_memory() >> 20) Mo possibles)"
    }

    // MARK: Interne

    /// État actuel : lecteur, vues suivies, fenêtres et listes à l'écran, mémoire, trousseau.
    @MainActor private static func state() -> String {
        let shown = places.sorted { $0.key < $1.key }.map { "  \($0.key) : \(rect($0.value))" }
        let app = UIApplication.shared.applicationState
        let head = "  app \(app == .active ? "active" : app == .inactive ? "inactive" : "en arrière-plan") · \(memory())"
        return ([head, player?.diagnosticState() ?? "  lecteur absent"] + shown + screen() + ["  \(keychain())"])
            .joined(separator: "\n")
    }

    @MainActor private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    /// Fenêtres, écrans présentés par-dessus, et listes défilantes (place, décalage, taille du contenu, visibles ou non).
    @MainActor private static func screen() -> [String] {
        var lines: [String] = []
        for scene in UIApplication.shared.connectedScenes {
            let active = scene.activationState
            let label = active == .foregroundActive ? "active" : active == .foregroundInactive ? "inactive" : active == .background ? "arrière-plan" : "détachée"
            lines.append("  scène \(label)")
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                lines.append("    fenêtre \(type(of: window)) \(rect(window.frame))\(window.isKeyWindow ? " principale" : "")\(window.isHidden ? " CACHÉE" : "") opacité \(window.alpha)")
                var shown = window.rootViewController
                while let controller = shown, lines.count < 40 {
                    lines.append("      écran \(type(of: controller))\(controller.isViewLoaded ? " \(rect(controller.view.frame))" : " pas chargé")")
                    shown = controller.presentedViewController
                }
                lists(in: window, window: window, depth: 0, into: &lines)
            }
        }
        return lines
    }

    /// Listes défilantes d'une fenêtre : place, décalage, taille du contenu, et si elles se voient vraiment.
    @MainActor private static func lists(in view: UIView, window: UIWindow, depth: Int, into lines: inout [String]) {
        guard depth < 80, lines.count < 80 else { return }
        if let list = view as? UIScrollView, !(view is UITextView) {
            var alpha = list.alpha
            var hidden = list.isHidden
            var parent = list.superview
            while let p = parent {
                alpha *= p.alpha
                hidden = hidden || p.isHidden
                parent = p.superview
            }
            let frame = list.convert(list.bounds, to: window)
            let seen = hidden ? "CACHÉE" : alpha < 0.01 ? "INVISIBLE" : frame.intersects(window.bounds) ? "visible" : "HORS ÉCRAN"
            lines.append("      liste \(rect(frame)) décalage \(Int(list.contentOffset.x)),\(Int(list.contentOffset.y)) contenu \(Int(list.contentSize.width))×\(Int(list.contentSize.height)) \(seen)")
        }
        for sub in view.subviews { lists(in: sub, window: window, depth: depth + 1, into: &lines) }
    }

    /// Part (en %) de la couleur la plus présente au-dessus de la barre d'onglets, sur une capture réduite de l'écran.
    @MainActor private static func sameColor(_ window: UIWindow) -> (Int, String) {
        let w = 40
        let h = max(1, Int(CGFloat(w) * window.bounds.height / max(window.bounds.width, 1)))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Repère d'UIKit (origine en haut) : la première ligne en mémoire est le haut de l'écran.
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            return window.drawHierarchy(in: CGRect(x: 0, y: 0, width: w, height: h), afterScreenUpdates: false)
        }
        let rows = h * 4 / 5 // le bas (barre d'onglets, mini-lecteur) est laissé de côté
        guard drawn, rows > 0 else { return (0, "capture impossible") }
        var counts: [Int: Int] = [:]
        for y in 0..<rows {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let red = Int(pixels[i] >> 4), green = Int(pixels[i + 1] >> 4), blue = Int(pixels[i + 2] >> 4)
                counts[red << 8 | green << 4 | blue, default: 0] += 1
            }
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return (0, "?") }
        return (top.value * 100 / (rows * w), String(format: "#%03lX", top.key))
    }

    private static func rect(_ r: CGRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
    }

    private static func write(_ line: String) {
        let data = Data(line.utf8)
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path) {
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            excludeFromBackup()
            return
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        // Plus de 128 Ko : seule la seconde moitié (la plus récente) est gardée.
        if size + UInt64(data.count) > 128 << 10, let all = try? Data(contentsOf: file) {
            let kept = all.suffix(64 << 10)
            let start = kept.firstIndex(of: 0x0A).map { kept.index(after: $0) } ?? kept.startIndex
            try? Data(kept[start...]).write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            excludeFromBackup()
        }
    }

    private static func excludeFromBackup() {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Signature de l'app, lue dans son profil d'installation : équipe, profil, date d'expiration, identifiant.
    private static func signing() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url) else { return "signature : pas de profil d'installation" }
        let text = String(decoding: raw, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = text[start.lowerBound..<end.upperBound].data(using: .utf8),
              let profile = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return "signature : profil illisible" }
        let team = (profile["TeamIdentifier"] as? [String])?.first ?? "?"
        let teamName = profile["TeamName"] as? String ?? "?"
        let name = profile["Name"] as? String ?? "?"
        let expires = (profile["ExpirationDate"] as? Date).map(stamp.string(from:)) ?? "?"
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? "?"
        let groups = (entitlements["keychain-access-groups"] as? [String])?.joined(separator: ",") ?? "aucun"
        return "signature : équipe \(team) (\(teamName)), profil « \(name) », expire le \(expires), app \(appID), groupes trousseau \(groups)"
    }
}

/// Plantages et blocages de l'app relevés par iOS (MetricKit), livrés au lancement suivant : notés dans le journal.
final class CrashReceiver: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReceiver()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let kind = "exception \(crash.exceptionType?.intValue ?? -1), code \(crash.exceptionCode?.intValue ?? -1), signal \(crash.signal?.intValue ?? -1)"
                let reason = [crash.terminationReason, crash.exceptionReason?.composedMessage].compactMap { $0 }.joined(separator: " · ")
                SessionLog.note("⚠️ PLANTAGE relevé par iOS (app \(crash.applicationVersion)) : \(kind) \(reason) · pile \(Self.frames(crash.callStackTree))")
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = String(format: "%.1f", hang.hangDuration.converted(to: .seconds).value)
                SessionLog.note("⚠️ BLOCAGE de l'app relevé par iOS (app \(hang.applicationVersion)) : \(seconds) s · pile \(Self.frames(hang.callStackTree))")
            }
        }
    }

    /// Haut de la pile du fil en cause : bibliothèque et position dans son code (20 appels au plus).
    private static func frames(_ tree: MXCallStackTree) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]] else { return "?" }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var out: [String] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, out.count < 20 {
            out.append("\(f["binaryName"] as? String ?? "?")+\(f["offsetIntoBinaryTextSegment"] as? Int ?? 0)")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out.joined(separator: " < ")
    }
}

/// Diagnostic temporaire (voir `SessionLog`) : note l'apparition, le retrait et la taille d'une vue, et garde sa place à
/// l'écran pour la copie du journal.
struct DiagnosticProbe: ViewModifier {
    /// Vide : rien n'est suivi.
    let name: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if name.isEmpty {
            content
        } else {
            content
                .onAppear { SessionLog.note("\(name) : affiché") }
                .onDisappear { SessionLog.note("\(name) : retiré") }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SessionLog.place(name, $0) }
        }
    }
}

extension UIWindow {
    /// iPhone secoué n'importe où dans l'app : le journal est copié (diagnostic temporaire, utile même écran noir).
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { SessionLog.copy() }
    }
}
