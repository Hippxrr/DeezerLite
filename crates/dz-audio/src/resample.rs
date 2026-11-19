//! Rééchantillonnage entrelacé f32 par blocs fixes (rubato).
//!
//! Résampleur FFT (synchrone, rapport fixe) : le filtre garde les aigus jusqu'à ~20 kHz et ne crée pas de fréquences
//! parasites. Avant : interpolation polynomiale cubique, qui atténuait les aigus (son étouffé) et repliait des
//! fréquences parasites (son dur) — or le son est presque toujours converti de 44,1 à 48 kHz (iPhone, PC et Mac).

use rubato::{FftFixedIn, Resampler as _};

const CHUNK: usize = 1024;

pub struct Resampler {
    inner: FftFixedIn<f32>,
    ch: usize,
    planar: Vec<Vec<f32>>,
    src: u64,
    dst: u64,
    /// Trames d'entrée reçues et trames de sortie rendues depuis le début (ou le dernier `reset`).
    fed: u64,
    emitted: u64,
    /// Trames de retard du filtre encore à jeter : le son reste calé sur la position (pas de silence ajouté au début).
    skip: usize,
}

impl Resampler {
    pub fn new(src: u32, dst: u32, ch: usize) -> Result<Self, String> {
        let inner = FftFixedIn::<f32>::new(src as usize, dst as usize, CHUNK, 2, ch).map_err(|e| format!("resampler: {e}"))?;
        let skip = inner.output_delay();
        Ok(Self { inner, ch, planar: vec![Vec::new(); ch], src: u64::from(src.max(1)), dst: u64::from(dst), fed: 0, emitted: 0, skip })
    }

    pub fn reset(&mut self) {
        self.inner.reset();
        for c in &mut self.planar {
            c.clear();
        }
        self.fed = 0;
        self.emitted = 0;
        self.skip = self.inner.output_delay();
    }

    /// Ajoute des échantillons entrelacés ; écrit en sortie ce qui est prêt (entrelacé).
    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        for frame in interleaved.chunks_exact(self.ch) {
            for (c, v) in frame.iter().enumerate() {
                self.planar[c].push(*v);
            }
            self.fed += 1;
        }
        while self.planar[0].len() >= CHUNK {
            let input: Vec<Vec<f32>> = self.planar.iter_mut().map(|c| c.drain(..CHUNK).collect()).collect();
            let Ok(res) = self.inner.process(&input, None) else { return };
            self.emit(&res, out);
        }
    }

    /// Fin du titre : le dernier bloc incomplet et ce que retient encore le filtre. Avant, les ~25 dernières
    /// millisecondes de chaque titre étaient perdues.
    pub fn flush(&mut self, out: &mut Vec<f32>) {
        let rest: Vec<Vec<f32>> = self.planar.iter_mut().map(std::mem::take).collect();
        if let Ok(res) = self.inner.process_partial(Some(rest.as_slice()), None) {
            self.emit(&res, out);
        }
        // Blocs de silence : seulement jusqu'à la durée attendue (rien de plus n'est rendu, voir `emit`).
        for _ in 0..4 {
            if self.emitted >= self.expected() {
                break;
            }
            match self.inner.process_partial::<Vec<f32>>(None, None) {
                Ok(res) => self.emit(&res, out),
                Err(_) => break,
            }
        }
    }

    fn expected(&self) -> u64 {
        self.fed * self.dst / self.src
    }

    fn emit(&mut self, res: &[Vec<f32>], out: &mut Vec<f32>) {
        let n = res.first().map_or(0, Vec::len);
        let expected = self.expected();
        for i in 0..n {
            if self.skip > 0 {
                self.skip -= 1;
                continue;
            }
            if self.emitted >= expected {
                break;
            }
            for c in res {
                out.push(c[i]);
            }
            self.emitted += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 44,1 -> 48 kHz : la durée est respectée (rien de perdu en fin de titre, rien d'ajouté), et un aigu à 16 kHz
    /// garde son niveau (l'ancien résampleur cubique l'atténuait nettement).
    #[test]
    fn keeps_length_and_treble() {
        let (src, dst) = (44_100u32, 48_000u32);
        let frames = src as usize; // 1 s
        let tone = |f: f32| -> Vec<f32> {
            (0..frames).flat_map(|i| {
                let v = 0.5 * (2.0 * std::f32::consts::PI * f * i as f32 / src as f32).sin();
                [v, v]
            }).collect()
        };
        for f in [1_000.0f32, 16_000.0] {
            let mut rs = Resampler::new(src, dst, 2).unwrap();
            let mut out = Vec::new();
            for block in tone(f).chunks(777 * 2) {
                rs.process(block, &mut out);
            }
            rs.flush(&mut out);
            assert_eq!(out.len() / 2, dst as usize, "1 s en entrée, 1 s en sortie");
            // Niveau efficace au milieu (loin des bords) : celui d'une sinusoïde d'amplitude 0,5 (0,354).
            let mid: Vec<f32> = out[dst as usize / 2..dst as usize].iter().step_by(2).copied().collect();
            let rms = (mid.iter().map(|v| v * v).sum::<f32>() / mid.len() as f32).sqrt();
            assert!((rms / 0.353_55 - 1.0).abs() < 0.02, "{f} Hz : niveau {rms}");
        }
    }
}
