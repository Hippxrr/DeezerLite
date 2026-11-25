import CryptoKit
import Foundation
import Security
import UIKit

/// Journal de connexion (temporaire : pour trouver pourquoi un iPhone perd sa session « au bout d'un moment »). Quelques
/// lignes aux moments clés (lancement, ouverture de session, connexion, déconnexion), jamais pendant la lecture : écrites
/// hors du fil de l'interface, dans un petit fichier gardé d'un lancement à l'autre (64 Ko au plus). Ni e-mail ni ARL :
/// seulement une empreinte courte de l'ARL, pour voir s'il a changé. Copié depuis le message de déconnexion.
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

    /// Une ligne datée. `detail` est calculé hors du fil de l'interface.
    static func note(_ detail: @escaping @Sendable () -> String) {
        let at = Date()
        queue.async { write("\(stamp.string(from: at))  \(detail())\n") }
    }

    static func note(_ text: String) { note { text } }

    /// Bloc complet au lancement : app, iOS, appareil, signature, conteneur, dossier de l'app, trousseau.
    @MainActor static func launch(folderExisted: Bool, sessionSaved: Bool) {
        let state = UIApplication.shared.applicationState
        let protected = UIApplication.shared.isProtectedDataAvailable
        let system = UIDevice.current.systemVersion
        note {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
            let up = Int(ProcessInfo.processInfo.systemUptime / 60)
            let launched = state == .background ? "en arrière-plan" : state == .inactive ? "inactive" : "à l'écran"
            return """
            ===== LANCEMENT : app \(version) · iOS \(system) · \(model())
              lancée \(launched) · données protégées \(protected ? "lisibles" : "verrouillées") · iPhone allumé depuis \(up / 60) h \(up % 60) min
              \(signing())
              conteneur \(URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent)
              dossier de l'app \(folderExisted ? "présent" : "ABSENT (nouvelle installation : session effacée du trousseau)") · session notée \(sessionSaved ? "oui" : "non")
              \(keychain())
            """
        }
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

    // MARK: Interne

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
        // Plus de 64 Ko : seule la seconde moitié (la plus récente) est gardée.
        if size + UInt64(data.count) > 64 << 10, let all = try? Data(contentsOf: file) {
            let kept = all.suffix(32 << 10)
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
