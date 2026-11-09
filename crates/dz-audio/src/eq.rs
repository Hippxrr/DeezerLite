//! Égaliseur cinq bandes (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) : cinq filtres biquad en série par canal — une
//! étagère de graves, trois cloches, une étagère d'aigus (la disposition des égaliseurs 5 bandes des apps de musique).
//!
//! Tout est calculé dans le rendu audio sans verrou ni allocation : les gains arrivent par des atomiques
//! (dixièmes de dB) et les coefficients ne sont recalculés que lorsqu'un gain change. Avec tous les gains à zéro,
//! le filtre est contourné : le son est strictement inchangé.

use std::f32::consts::PI;

/// Nombre maximal de canaux traités (au-delà, les canaux supplémentaires passent sans filtre).
pub const MAX_CH: usize = 8;

/// Nombre de bandes.
pub const BANDS: usize = 5;
/// Fréquence de chaque bande (Hz) : étagère de graves, trois cloches, étagère d'aigus.
pub const BANDS_HZ: [f32; BANDS] = [60.0, 230.0, 910.0, 3_600.0, 14_000.0];
/// Largeur des cloches : une bande déborde un peu sur ses voisines, la courbe reste douce.
const PEAK_Q: f32 = 1.0;

/// Coefficients normalisés (a0 = 1) d'un filtre biquad.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Coef {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
}

impl Coef {
    const IDENTITY: Coef = Coef { b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0 };

    fn normalized(b0: f32, b1: f32, b2: f32, a0: f32, a1: f32, a2: f32) -> Self {
        Coef { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }
}

/// Étagère de graves (RBJ, pente 1).
pub fn low_shelf(fs: f32, f0: f32, gain_db: f32) -> Coef {
    if gain_db == 0.0 {
        return Coef::IDENTITY;
    }
    let a = 10f32.powf(gain_db / 40.0);
    let w = 2.0 * PI * f0 / fs;
    let (sin, cos) = w.sin_cos();
    let alpha = sin / 2.0 * 2f32.sqrt(); // S = 1
    let sq = 2.0 * a.sqrt() * alpha;
    Coef::normalized(
        a * ((a + 1.0) - (a - 1.0) * cos + sq),
        2.0 * a * ((a - 1.0) - (a + 1.0) * cos),
        a * ((a + 1.0) - (a - 1.0) * cos - sq),
        (a + 1.0) + (a - 1.0) * cos + sq,
        -2.0 * ((a - 1.0) + (a + 1.0) * cos),
        (a + 1.0) + (a - 1.0) * cos - sq,
    )
}

/// Étagère d'aigus (RBJ, pente 1).
pub fn high_shelf(fs: f32, f0: f32, gain_db: f32) -> Coef {
    if gain_db == 0.0 {
        return Coef::IDENTITY;
    }
    let a = 10f32.powf(gain_db / 40.0);
    let w = 2.0 * PI * f0 / fs;
    let (sin, cos) = w.sin_cos();
    let alpha = sin / 2.0 * 2f32.sqrt();
    let sq = 2.0 * a.sqrt() * alpha;
    Coef::normalized(
        a * ((a + 1.0) + (a - 1.0) * cos + sq),
        -2.0 * a * ((a - 1.0) + (a + 1.0) * cos),
        a * ((a + 1.0) + (a - 1.0) * cos - sq),
        (a + 1.0) - (a - 1.0) * cos + sq,
        2.0 * ((a - 1.0) - (a + 1.0) * cos),
        (a + 1.0) - (a - 1.0) * cos - sq,
    )
}

/// Filtre en cloche (RBJ).
pub fn peaking(fs: f32, f0: f32, q: f32, gain_db: f32) -> Coef {
    if gain_db == 0.0 {
        return Coef::IDENTITY;
    }
    let a = 10f32.powf(gain_db / 40.0);
    let w = 2.0 * PI * f0 / fs;
    let (sin, cos) = w.sin_cos();
    let alpha = sin / (2.0 * q);
    Coef::normalized(1.0 + alpha * a, -2.0 * cos, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * cos, 1.0 - alpha / a)
}

/// État de l'égaliseur d'un flux : coefficients courants et mémoire des filtres, par canal et par bande.
pub struct EqState {
    rate: f32,
    channels: usize,
    coefs: [Coef; BANDS],
    /// Dernier réglage appliqué (dixièmes de dB, une valeur par bande).
    applied: [i32; BANDS],
    on: bool,
    z: [[[f32; 2]; BANDS]; MAX_CH],
}

impl EqState {
    pub fn new(rate: u32, channels: usize) -> Self {
        Self {
            rate: rate as f32,
            channels,
            coefs: [Coef::IDENTITY; BANDS],
            applied: [0; BANDS],
            on: false,
            z: [[[0.0; 2]; BANDS]; MAX_CH],
        }
    }

    /// Prend en compte un nouveau réglage (dixièmes de dB, une valeur par bande) ; ne recalcule que s'il a changé.
    pub fn set(&mut self, gains: [i32; BANDS]) {
        if gains == self.applied {
            return;
        }
        // Bande revenue à 0 dB : sa mémoire est vidée (sinon un reste s'ajouterait au son suivant, un petit clic).
        for (i, (&new, &old)) in gains.iter().zip(&self.applied).enumerate() {
            if new == 0 && old != 0 {
                self.z.iter_mut().for_each(|ch| ch[i] = [0.0; 2]);
            }
        }
        self.applied = gains;
        let db = |t: i32| t as f32 / 10.0;
        let last = BANDS - 1;
        // Une étagère d'aigus au-delà de la moitié de la fréquence d'échantillonnage n'a pas de sens : ramenée en dessous.
        let top = BANDS_HZ[last].min(self.rate * 0.45);
        self.coefs = std::array::from_fn(|i| match i {
            0 => low_shelf(self.rate, BANDS_HZ[0], db(gains[0])),
            i if i == last => high_shelf(self.rate, top, db(gains[i])),
            i => peaking(self.rate, BANDS_HZ[i], PEAK_Q, db(gains[i])),
        });
        self.on = gains != [0; BANDS];
        if !self.on {
            self.z = [[[0.0; 2]; BANDS]; MAX_CH];
        }
    }

    /// Vrai si au moins une bande modifie le son (le limiteur doit alors rester actif : un gain positif peut dépasser 1,0).
    pub fn active(&self) -> bool {
        self.on
    }

    /// Filtre l'échantillon `x` du canal `ch`.
    #[inline]
    pub fn process(&mut self, ch: usize, x: f32) -> f32 {
        if !self.on || ch >= self.channels.min(MAX_CH) {
            return x;
        }
        let mut y = x;
        for (band, c) in self.coefs.iter().enumerate() {
            let z = &mut self.z[ch][band];
            let out = c.b0 * y + z[0];
            z[0] = c.b1 * y - c.a1 * out + z[1];
            z[1] = c.b2 * y - c.a2 * out;
            // Silence : les mémoires décroissent vers des nombres minuscules (dénormaux) très lents à calculer sur PC.
            if z[0].abs() < 1e-20 {
                z[0] = 0.0;
            }
            if z[1].abs() < 1e-20 {
                z[1] = 0.0;
            }
            y = out;
        }
        y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Gain mesuré (en dB) d'un réglage sur une sinusoïde de fréquence `hz`.
    fn gain_at(rate: u32, gains: [i32; BANDS], hz: f32) -> f32 {
        let mut st = EqState::new(rate, 2);
        st.set(gains);
        let fs = rate as f32;
        let n = (fs as usize) / 2;
        let (mut sum_in, mut sum_out) = (0.0f64, 0.0f64);
        for i in 0..n {
            let x = (2.0 * PI * hz * i as f32 / fs).sin() * 0.25;
            let y = st.process(0, x);
            if i > n / 2 {
                // on ignore le régime transitoire
                sum_in += (x * x) as f64;
                sum_out += (y * y) as f64;
            }
        }
        (10.0 * (sum_out / sum_in).log10()) as f32
    }

    #[test]
    fn flat_settings_leave_the_signal_untouched() {
        let mut st = EqState::new(44_100, 2);
        st.set([0; BANDS]);
        assert!(!st.active());
        assert_eq!(st.process(0, 0.37), 0.37);
        assert_eq!(st.process(1, -0.5), -0.5);
    }

    #[test]
    fn bass_boost_raises_lows_only() {
        let low = gain_at(44_100, [80, 0, 0, 0, 0], 30.0);
        let high = gain_at(44_100, [80, 0, 0, 0, 0], 5_000.0);
        assert!((low - 8.0).abs() < 1.5, "graves : {low} dB");
        assert!(high.abs() < 0.8, "aigus intacts : {high} dB");
    }

    #[test]
    fn treble_cut_lowers_highs_only() {
        let high = gain_at(48_000, [0, 0, 0, 0, -60], 19_000.0);
        let low = gain_at(48_000, [0, 0, 0, 0, -60], 200.0);
        assert!((high + 6.0).abs() < 1.5, "aigus : {high} dB");
        assert!(low.abs() < 0.8, "graves intacts : {low} dB");
    }

    #[test]
    fn each_middle_band_is_centred_on_its_frequency() {
        for (band, hz) in [(1, 230.0), (2, 910.0), (3, 3_600.0)] {
            let mut gains = [0; BANDS];
            gains[band] = 60;
            let centre = gain_at(44_100, gains, hz);
            let far = gain_at(44_100, gains, if hz > 1_000.0 { 60.0 } else { 12_000.0 });
            assert!((centre - 6.0).abs() < 1.0, "bande {band} au centre : {centre} dB");
            assert!(far.abs() < 1.0, "bande {band} loin du centre : {far} dB");
        }
    }

    #[test]
    fn returning_to_flat_clears_the_filter_memory() {
        let mut st = EqState::new(44_100, 2);
        st.set([100; BANDS]);
        for i in 0..1000 {
            st.process(0, (i as f32 * 0.1).sin());
        }
        st.set([0; BANDS]);
        assert!(!st.active());
        assert_eq!(st.process(0, 0.25), 0.25);
    }
}
