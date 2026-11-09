//! Rééchantillonnage entrelacé f32 par blocs fixes (rubato).

use rubato::{FastFixedIn, PolynomialDegree, Resampler as _};

const CHUNK: usize = 1024;

pub struct Resampler {
    inner: FastFixedIn<f32>,
    ch: usize,
    planar: Vec<Vec<f32>>,
}

impl Resampler {
    pub fn new(src: u32, dst: u32, ch: usize) -> Result<Self, String> {
        let ratio = dst as f64 / src as f64;
        let inner = FastFixedIn::<f32>::new(ratio, 1.0, PolynomialDegree::Cubic, CHUNK, ch)
            .map_err(|e| format!("resampler: {e}"))?;
        Ok(Self { inner, ch, planar: vec![Vec::new(); ch] })
    }

    pub fn reset(&mut self) {
        self.inner.reset();
        for c in &mut self.planar {
            c.clear();
        }
    }

    /// Ajoute des échantillons entrelacés ; écrit en sortie ce qui est prêt (entrelacé).
    pub fn process(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        for frame in interleaved.chunks_exact(self.ch) {
            for (c, v) in frame.iter().enumerate() {
                self.planar[c].push(*v);
            }
        }
        while self.planar[0].len() >= CHUNK {
            let input: Vec<Vec<f32>> = self.planar.iter_mut().map(|c| c.drain(..CHUNK).collect()).collect();
            let Ok(res) = self.inner.process(&input, None) else { return };
            let n = res.first().map_or(0, Vec::len);
            for i in 0..n {
                for c in &res {
                    out.push(c[i]);
                }
            }
        }
    }
}
