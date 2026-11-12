import AVFoundation
import CoreMotion
import Observation
import UIKit

/// TEMPORAIRE (test AirPods, à retirer après) : pourquoi le retrait d'un seul AirPod ne met pas en pause.
/// - un journal de tout ce qu'iOS envoie à l'app (commandes, sorties, coupures), affiché dans Réglages › Son ;
/// - des essais à activer ou non (appliqués au lancement), pour trouver ce qu'iOS attend avant d'envoyer la pause ;
/// - deux relevés pour détecter le retrait nous-mêmes si iOS n'envoie rien : la sortie audio (toutes les 0,5 s) et
///   les capteurs de mouvement des AirPods (quel écouteur les fournit).
@MainActor @Observable
final class AirPodsDiag {
    static let shared = AirPodsDiag()

    // MARK: Essais (Réglages › Son, appliqués au prochain lancement)

    /// Session sans le mode « audio long » (`.longFormAudio`).
    nonisolated static let plainPolicyKey = "diagPlainPolicy"
    /// État de lecture déclaré à iOS (`MPNowPlayingInfoCenter.playbackState`), en plus de celui qu'il devine.
    nonisolated static let stateKey = "diagState"
    /// Ancienne inscription aux commandes à distance (`beginReceivingRemoteControlEvents`).
    nonisolated static let legacyKey = "diagLegacy"
    /// Lecteur d'Apple (AVPlayer) qui joue du silence pendant la musique : iOS voit alors un lecteur à lui jouer.
    nonisolated static let silentKey = "diagSilent"
    /// Capteurs de mouvement des AirPods (demande l'autorisation « Mouvements et forme »).
    nonisolated static let motionKey = "diagMotion"

    nonisolated private static let registered: Void = {
        UserDefaults.standard.register(defaults: [stateKey: true, legacyKey: true, silentKey: true, motionKey: true])
    }()
    nonisolated static func on(_ key: String) -> Bool {
        _ = registered
        return UserDefaults.standard.bool(forKey: key)
    }
    nonisolated static var plainPolicy: Bool { on(plainPolicyKey) }

    // MARK: Journal

    private(set) var lines: [String] = []
    @ObservationIgnored private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: String) {
        lines.insert("\(clock.string(from: Date()))  \(text)", at: 0)
        if lines.count > 120 { lines.removeLast() }
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

    // MARK: Lancement

    /// Au lancement (avant les commandes à distance) : ce qui est actif, puis les essais et les relevés.
    func start() {
        let sideloaded = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        log("Lancement · iOS \(UIDevice.current.systemVersion) · \(Bundle.main.bundleIdentifier ?? "?") · profil d'installation : \(sideloaded ? "oui" : "non")")
        func mark(_ key: String) -> String { AirPodsDiag.on(key) ? "OUI" : "non" }
        log("Essais : audio long désactivé \(mark(Self.plainPolicyKey)) · état déclaré \(mark(Self.stateKey)) · ancienne inscription \(mark(Self.legacyKey)) · lecteur Apple muet \(mark(Self.silentKey)) · capteurs \(mark(Self.motionKey))")
        if Self.on(Self.legacyKey) { UIApplication.shared.beginReceivingRemoteControlEvents() }
        if Self.on(Self.motionKey) { startMotion() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { AirPodsDiag.shared.checkRoute() }
        }
    }

    // MARK: Relevé de la sortie

    @ObservationIgnored private var lastRoute = ""

    /// Sortie actuelle, nombre de canaux compris : retirer un AirPod change peut-être quelque chose ici sans prévenir.
    private func checkRoute() {
        let s = AVAudioSession.sharedInstance()
        let outputs = s.currentRoute.outputs.map { o in
            "\(o.portName) (\(o.channels?.count ?? 0) canaux\(o.selectedDataSource.map { ", " + $0.dataSourceName } ?? ""))"
        }
        let sig = (outputs.isEmpty ? "aucune" : outputs.joined(separator: ", ")) + " · \(s.outputNumberOfChannels) canaux en sortie"
        guard sig != lastRoute else { return }
        log("\(lastRoute.isEmpty ? "Sortie au départ" : "Sortie relevée") : \(sig)")
        lastRoute = sig
    }

    // MARK: Lecteur d'Apple muet

    @ObservationIgnored private var silent: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    /// Ce que l'app a demandé au lecteur muet (lecture ou pause).
    @ObservationIgnored private var silentWanted = false

    /// Joue du silence avec un lecteur d'Apple tant que la musique joue (essai « lecteur Apple muet »).
    func silentPlayer(playing: Bool) {
        guard Self.on(Self.silentKey) else { return }
        if silent == nil {
            guard let url = Self.silenceFile() else {
                log("Lecteur Apple muet : fichier de silence impossible à créer")
                return
            }
            let player = AVQueuePlayer()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            silent = player
            // Si iOS met ce lecteur en pause au retrait d'un AirPod (même sans rien envoyer à l'app), ça se verra ici.
            // Et s'il s'arrête sans qu'on le demande (hors appel), la musique est mise en pause avec lui, après 0,3 s : écouteurs
            // débranchés, la pause habituelle passe d'abord (sa reprise au retour des écouteurs reste prévue).
            NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { n in
                let reason = (n.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason)
                let rate = (n.object as? AVPlayer)?.rate ?? -1
                MainActor.assumeIsolated {
                    AirPodsDiag.shared.log("Lecteur Apple muet : vitesse \(rate) · raison \(reason?.rawValue ?? "?")")
                    guard rate == 0, reason != .audioSessionInterrupted else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            guard AirPodsDiag.shared.silentWanted, Player.shared.status.playing else { return }
                            AirPodsDiag.shared.log("→ arrêté sans qu'on le demande : la musique est mise en pause")
                            Player.shared.pause()
                        }
                    }
                }
            }
            log("Lecteur Apple muet : prêt")
        }
        silentWanted = playing
        if playing { silent?.play() } else { silent?.pause() }
    }

    /// Deux secondes de silence (WAV 44,1 kHz, 16 bits, stéréo), écrites une fois.
    nonisolated private static func silenceFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let dataLen = UInt32(44_100 * 4 * 2)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + dataLen)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(44_100)); put(UInt32(44_100 * 4)); put(UInt16(4)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(dataLen)
        d.append(Data(count: Int(dataLen)))
        return (try? d.write(to: url)) != nil ? url : nil
    }

    // MARK: Capteurs des AirPods

    @ObservationIgnored private var motion: CMHeadphoneMotionManager?
    @ObservationIgnored private var motionDelegate: MotionDelegate?
    @ObservationIgnored private var lastSensor: Int?

    private func startMotion() {
        let m = CMHeadphoneMotionManager()
        guard m.isDeviceMotionAvailable else {
            log("Capteurs des AirPods : indisponibles")
            return
        }
        let d = MotionDelegate()
        m.delegate = d
        m.startDeviceMotionUpdates(to: .main) { data, error in
            let raw = data.map { $0.sensorLocation.rawValue }
            let message = error?.localizedDescription
            MainActor.assumeIsolated { AirPodsDiag.shared.sensor(raw, message) }
        }
        motion = m
        motionDelegate = d
        log("Capteurs des AirPods : démarrés")
    }

    /// N'écrit que les changements : quel écouteur fournit le mouvement (il change peut-être au retrait d'un AirPod).
    fileprivate func sensor(_ raw: Int?, _ error: String?) {
        if let error {
            log("Capteurs : erreur \(error)")
            return
        }
        guard let raw, raw != lastSensor else { return }
        lastSensor = raw
        let names = [0: "par défaut", 1: "AirPod gauche", 2: "AirPod droit"]
        log("Capteurs : mouvement lu sur \(names[raw] ?? "\(raw)")")
    }
}

/// Branchement et retrait des AirPods vus par les capteurs de mouvement.
private final class MotionDelegate: NSObject, CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        AirPodsDiag.note("Capteurs : AirPods connectés")
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        AirPodsDiag.note("Capteurs : AirPods déconnectés")
    }
}
