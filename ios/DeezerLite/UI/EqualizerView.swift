import SwiftUI

/// Égaliseur, comme celui de Deezer : interrupteur, cinq curseurs verticaux (-12 à +12 dB), préréglage en bas avec des
/// flèches pour passer au suivant. Toucher un curseur d'un préréglage le recopie dans « Personnalisé ».
struct EqualizerPanel: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            Toggle(isOn: Binding(get: { player.eqPreset != .off }, set: { on in withAnimation(.easeOut(duration: 0.2)) { player.setEqOn(on) } })) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.vertical.3").foregroundStyle(Theme.accent).frame(width: 26)
                    Text(tr("Égaliseur"))
                }
            }
            .tint(Theme.accent)
            .padding(14)

            if player.eqPreset != .off {
                Divider().padding(.leading, 52)
                HStack(alignment: .top, spacing: 0) {
                    // Graduations : +12, 0, -12.
                    VStack {
                        Text("+12")
                        Spacer()
                        Text("0")
                        Spacer()
                        Text("-12")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, height: EqBandSlider.height)
                    ForEach(EqPreset.bands.indices, id: \.self) { b in
                        VStack(spacing: 8) {
                            EqBandSlider(band: EqPreset.bands[b], value: player.eqGains[b]) { player.setEqBand(b, $0) }
                            Text(EqPreset.bands[b]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 16)

                // Préréglage : flèches pour passer au précédent / au suivant.
                HStack {
                    Button { player.stepEqPreset(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Préréglage précédent"))
                    Spacer()
                    Text(player.eqPreset.name).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.opacity)
                    Spacer()
                    Button { player.stepEqPreset(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Préréglage suivant"))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.15), value: player.eqPreset)
            }
        }
        .sensoryFeedback(.selection, trigger: player.eqPreset)
    }
}

/// Curseur vertical d'une bande (-12 à +12 dB, par pas de 1 dB) : on fait glisser la poignée, ou on touche la piste.
/// Seule la poignée se fait glisser : le doigt posé ailleurs sur la piste laisse défiler la page des réglages.
struct EqBandSlider: View {
    static let height: CGFloat = 220
    /// Nom de la bande (« 60 », « 3,6k »…), lu par VoiceOver.
    let band: String
    let value: Double
    let onChange: (Double) -> Void
    private let knob = CGSize(width: 34, height: 26)
    /// Écart entre le doigt et le centre de la poignée au début du glissement : la poignée ne saute pas sous le doigt.
    /// Repris à chaque nouveau geste (autre point de départ) : un geste interrompu (appel) ne le laisse plus au suivant.
    @State private var grab: (from: CGPoint, offset: CGFloat)?
    /// Changements faits ici (glissement, appui) : seuls eux font vibrer, pas un changement de préréglage.
    @State private var touches = 0

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - knob.height
            let y = (1 - (value + 12) / 24) * travel
            let db = { (at: CGFloat) -> Double in
                let t = min(max((at - knob.height / 2) / travel, 0), 1)
                return ((1 - t) * 24 - 12).rounded()
            }
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 6).frame(maxHeight: .infinity)
                // Trait du 0 dB.
                Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 18, height: 1).offset(y: travel / 2 + knob.height / 2)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(value == 0 ? Color.white : Theme.accent)
                    .overlay { Capsule().fill(value == 0 ? Color.black.opacity(0.6) : Theme.onAccent).frame(width: 14, height: 2) }
                    .frame(width: knob.width, height: knob.height)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    // Zone de prise plus grande que la poignée dessinée (10 pt de plus de chaque côté).
                    .frame(width: knob.width + 20, height: knob.height + 20)
                    .contentShape(Rectangle())
                    .offset(y: y - 10)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("eqTrack"))
                            .onChanged { g in
                                if grab?.from != g.startLocation { grab = (g.startLocation, g.startLocation.y - (y + knob.height / 2)) }
                                let v = db(g.location.y - (grab?.offset ?? 0))
                                if v != value { onChange(v); touches += 1 }
                            }
                            .onEnded { _ in grab = nil }
                    )
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { at in
                let v = db(at.y)
                if v != value { onChange(v); touches += 1 }
            }
            .coordinateSpace(.named("eqTrack"))
        }
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: touches)
        .accessibilityElement()
        .accessibilityLabel("\(band) Hz")
        .accessibilityValue("\(Int(value)) dB")
        .accessibilityAdjustableAction { dir in onChange(min(max(value + (dir == .increment ? 1 : -1), -12), 12)) }
    }
}
