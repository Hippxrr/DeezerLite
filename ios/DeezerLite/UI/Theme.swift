import Observation
import SwiftUI

/// Couleurs de l'app. Onze thèmes en couleurs unies (pas de dégradé) ; le premier est celui de la version bureau.
/// Les vues lisent `Theme.accent` / `Theme.background` : la lecture passe par `ThemeStore`, observé par SwiftUI,
/// donc changer de thème recolore aussitôt tout ce qui est affiché, sans rien reconstruire.
/// Chaque couleur a sa version sombre et sa version claire : iOS prend la bonne selon le mode affiché
/// (Réglages > Apparence > Mode), sans que les vues aient à s'en occuper.
enum Theme {
    struct Palette: Identifiable, Equatable {
        let id: String
        let name: String
        /// Accent en mode sombre (celui de la version bureau).
        let darkAccent: UInt32
        /// Accent en mode clair : les accents très clairs sont foncés pour rester lisibles sur fond blanc.
        let lightAccent: UInt32
        let darkBackground: UInt32
        /// Couleurs construites une seule fois (une couleur refaite à chaque lecture n'est jamais égale à la
        /// précédente : redessins en trop, animations qui repartent).
        let accent: Color
        /// Fond clair : blanc à peine teinté par l'accent.
        let background: Color
        /// Texte posé sur l'accent : noir sur les accents très clairs du mode sombre, blanc sinon.
        let onAccent: Color

        init(id: String, name: String, accent: UInt32, background: UInt32, light: UInt32? = nil, darkText: Bool = false) {
            self.id = id
            self.name = name
            darkAccent = accent
            lightAccent = light ?? accent
            darkBackground = background
            self.accent = Theme.dynamic(dark: darkAccent, light: lightAccent)
            self.background = Theme.dynamic(dark: darkBackground, light: Theme.blend(0xF7F7FA, lightAccent, 0.05))
            onAccent = Color(UIColor { $0.userInterfaceStyle == .dark && darkText ? .black : .white })
        }
    }

    static let palettes: [Palette] = [
        Palette(id: "violet", name: "Violet", accent: 0xA238FF, background: 0x0B0A10),
        Palette(id: "ocean", name: "Océan", accent: 0x3B9DFF, background: 0x060D16, light: 0x1F7FE0),
        Palette(id: "rose", name: "Rose", accent: 0xFF4F9A, background: 0x14070E, light: 0xE6337F),
        Palette(id: "emerald", name: "Émeraude", accent: 0x2ECC8F, background: 0x07120E, light: 0x14996A),
        Palette(id: "amber", name: "Ambre", accent: 0xFFB020, background: 0x120E06, light: 0xA35F00, darkText: true),
        Palette(id: "graphite", name: "Graphite", accent: 0xE6E6EB, background: 0x000000, light: 0x1C1C1E, darkText: true),
        Palette(id: "red", name: "Rouge", accent: 0xFF4545, background: 0x140707, light: 0xE02B2B),
        Palette(id: "orange", name: "Orange", accent: 0xFF7A1A, background: 0x140A04, light: 0xE5630A),
        Palette(id: "lime", name: "Citron vert", accent: 0xA3E635, background: 0x0B1206, light: 0x3F7310, darkText: true),
        Palette(id: "cyan", name: "Cyan", accent: 0x22D3EE, background: 0x051216, light: 0x0891B2, darkText: true),
        Palette(id: "indigo", name: "Indigo", accent: 0x6E72FF, background: 0x08081A),
    ]

    static var accent: Color { ThemeStore.shared.palette.accent }
    static var background: Color { ThemeStore.shared.backgroundColor }
    /// Texte posé sur la couleur d'accent (noir sur les accents très clairs du mode sombre, comme Graphite ou Ambre).
    static var onAccent: Color { ThemeStore.shared.palette.onAccent }
    /// Cartes et emplacements vides : un voile blanc sur fond sombre, un voile gris sur fond clair.
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.05) })
    static let radius: CGFloat = 12

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        let (d, l) = (uiColor(dark), uiColor(light))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    private static func uiColor(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// `a` mélangé à `b` dans la proportion `t` (0 = tout `a`).
    fileprivate static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return mix(16) | mix(8) | mix(0)
    }
}

/// Fond de l'app en mode sombre, choisi dans Réglages > Apparence.
enum AppBackground: String, CaseIterable, Identifiable {
    case black, oled, slate, plum

    var id: String { rawValue }

    /// Nom (français : clé de `tr`).
    var name: String {
        switch self {
        case .black: "Noir"
        case .oled: "Noir OLED"
        case .slate: "Bleu ardoise"
        case .plum: "Prune"
        }
    }

    var hex: UInt32 {
        switch self {
        case .black: 0x121216
        case .oled: 0x000000
        case .slate: 0x1B2531
        case .plum: 0x201826
        }
    }

    var color: Color { Theme.dynamic(dark: hex, light: hex) }
}

/// Mode d'affichage choisi dans Réglages > Apparence.
enum Appearance: String, CaseIterable {
    case dark, light, system

    var title: String {
        switch self {
        case .dark: tr("Sombre")
        case .light: tr("Clair")
        case .system: tr("Système")
        }
    }

    /// `.unspecified` : celui de l'iPhone (il suit le passage jour / nuit s'il est automatique).
    var style: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
    }
}

@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var palette: Theme.Palette
    /// Sombre (celui d'origine), clair, ou celui de l'iPhone.
    private(set) var appearance: Appearance
    /// Fond de l'app en mode sombre.
    private(set) var background: AppBackground
    /// Couleur du fond (sombre : celle choisie ; clair : blanc teinté par l'accent), construite une seule fois.
    private(set) var backgroundColor: Color

    private static func color(_ background: AppBackground, _ palette: Theme.Palette) -> Color {
        Theme.dynamic(dark: background.hex, light: Theme.blend(0xF7F7FA, palette.lightAccent, 0.05))
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "theme")
        let first = Theme.palettes.first { $0.id == saved } ?? Theme.palettes[0]
        palette = first
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark
        let chosen = AppBackground(rawValue: UserDefaults.standard.string(forKey: "background") ?? "") ?? .black
        background = chosen
        backgroundColor = Self.color(chosen, first)
    }

    func setBackground(_ b: AppBackground) {
        background = b
        backgroundColor = Self.color(b, palette)
        UserDefaults.standard.set(b.rawValue, forKey: "background")
    }

    func setAppearance(_ a: Appearance) {
        appearance = a
        // Sombre (par défaut) : rien de gardé.
        if a == .dark { UserDefaults.standard.removeObject(forKey: "appearance") } else { UserDefaults.standard.set(a.rawValue, forKey: "appearance") }
        let style = a.style
        Task { @MainActor in Self.applyStyle(style, animated: true) }
    }

    /// Le mode est posé sur les fenêtres de l'app (pas CarPlay), jamais avec `preferredColorScheme` : son `nil` n'efface
    /// pas toujours le mode déjà imposé, et « Système » restait alors bloqué sur le dernier choix.
    @MainActor
    static func applyStyle(_ style: UIUserInterfaceStyle, animated: Bool = false) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                if animated {
                    UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: {
                        window.overrideUserInterfaceStyle = style
                    })
                } else {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }

    func select(_ id: String) {
        guard let p = Theme.palettes.first(where: { $0.id == id }) else { return }
        palette = p
        backgroundColor = Self.color(background, p)
        UserDefaults.standard.set(id, forKey: "theme")
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Date « AAAA-MM-JJ » de Deezer en toutes lettres : « 20 octobre 2026 », « Aujourd'hui » ou « Hier ».
/// Une date incomplète (« 2026 », « 2026-10 ») ou illisible est rendue telle quelle.
func formatDay(_ iso: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.calendar = Calendar(identifier: .gregorian)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return tr("Aujourd'hui") }
    if calendar.isDateInYesterday(date) { return tr("Hier") }
    return date.formatted(.dateTime.day().month(.wide).year().locale(LanguageStore.shared.locale))
}

/// Fond choisi dans les réglages, sous le contenu d'une page. Posé sur chaque page : la pile de navigation a son propre
/// fond, qui cachait celui posé derrière la barre d'onglets. À part pour suivre le réglage dès qu'il change.
private struct PageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.background.ignoresSafeArea())
    }
}

extension View {
    func pageBackground() -> some View { modifier(PageBackground()) }

    /// Surface de l'app : Liquid Glass qui réagit au toucher (iOS 26), carte sombre sur les iOS plus anciens.
    /// `tint` : verre teinté (bouton principal, choix sélectionné) ; `material` : repli flou plutôt qu'opaque
    /// pour ce qui flotte au-dessus du contenu (mini-lecteur, bulles).
    @ViewBuilder
    func surface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true, material: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                self.modifier(InteractiveGlass(shape: shape, tint: tint))
            } else {
                self.glassEffect(liquidGlass(tint: tint, interactive: false), in: shape)
            }
        } else {
            self.flatSurface(shape, tint: tint, material: material)
        }
        #else
        self.flatSurface(shape, tint: tint, material: material)
        #endif
    }

    @ViewBuilder
    private func flatSurface<S: Shape>(_ shape: S, tint: Color?, material: Bool) -> some View {
        if let tint {
            self.background(tint, in: shape)
        } else if material {
            self.background(.ultraThinMaterial, in: shape)
        } else {
            self.background(Theme.card, in: shape)
        }
    }
}

extension View {
    /// Fond d'une feuille (Réglages, Crédits) : teinte en haut. Avec Liquid Glass, pas de fond opaque : la feuille
    /// d'iOS 26 reste en verre et les cartes en verre ont des couleurs à réfracter au lieu d'un aplat noir.
    @ViewBuilder
    func sheetBackground(_ tint: Color, strength: Double) -> some View {
        let gradient = LinearGradient(colors: [tint.opacity(strength), .clear], startPoint: .top, endPoint: .center)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.background { gradient.ignoresSafeArea() }
        } else {
            self.background { ZStack { Theme.background; gradient }.ignoresSafeArea() }
        }
        #else
        self.background { ZStack { Theme.background; gradient }.ignoresSafeArea() }
        #endif
    }
}

extension EnvironmentValues {
    /// `false` : le verre des surfaces ne réagit plus au doigt (pages cachées sous le grand lecteur).
    @Entry var glassReactsToTouch = true
}

#if compiler(>=6.2)
/// Verre qui réagit au toucher, sauf quand la page est cachée sous le grand lecteur : iOS fait réagir le verre au doigt
/// même à travers ce qui est posé par-dessus (le lecteur), et l'effet d'appui apparaissait sur la page quand il descendait.
@available(iOS 26.0, *)
private struct InteractiveGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    @Environment(\.glassReactsToTouch) private var reacts

    func body(content: Content) -> some View {
        content.glassEffect(liquidGlass(tint: tint, interactive: reacts), in: shape)
    }
}

@available(iOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    return interactive ? glass.interactive() : glass
}
#endif
