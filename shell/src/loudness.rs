//! Integrated loudness (ITU-R BS.1770, EBU R128) of a rendered file, as the
//! app's meter measures it (rive/src/synth/mixer.as): K-weighting, 400 ms
//! blocks every 100 ms, an absolute gate at -70 LUFS and a relative gate 10 LU
//! under the gated mean.

use crate::wav::Audio;

struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    z: [f64; 2],
}

impl Biquad {
    fn new(b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64) -> Self {
        Biquad { b: [b0 / a0, b1 / a0, b2 / a0], a: [a1 / a0, a2 / a0], z: [0.0; 2] }
    }

    fn high_shelf(f: f64, gain_db: f64, sr: f64) -> Self {
        let a = 10f64.powf(gain_db / 40.0);
        let w = 2.0 * std::f64::consts::PI * f / sr;
        let (s, c) = w.sin_cos();
        let alpha = s / 2.0 * std::f64::consts::SQRT_2;
        let sa = 2.0 * a.sqrt() * alpha;
        Self::new(
            a * ((a + 1.0) + (a - 1.0) * c + sa),
            -2.0 * a * ((a - 1.0) + (a + 1.0) * c),
            a * ((a + 1.0) + (a - 1.0) * c - sa),
            (a + 1.0) - (a - 1.0) * c + sa,
            2.0 * ((a - 1.0) - (a + 1.0) * c),
            (a + 1.0) - (a - 1.0) * c - sa,
        )
    }

    fn high_pass(f: f64, q: f64, sr: f64) -> Self {
        let w = 2.0 * std::f64::consts::PI * f / sr;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * q);
        Self::new((1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0, 1.0 + alpha, -2.0 * c, 1.0 - alpha)
    }

    fn process(&mut self, x: f64) -> f64 {
        let y = self.b[0] * x + self.z[0];
        self.z[0] = self.b[1] * x - self.a[0] * y + self.z[1];
        self.z[1] = self.b[2] * x - self.a[1] * y;
        y
    }
}

fn lufs(mean_square: f64) -> f64 {
    if mean_square > 1e-12 { -0.691 + 10.0 * mean_square.log10() } else { f64::NEG_INFINITY }
}

/// The integrated loudness in LUFS (-inf for silence).
pub fn integrated(audio: &Audio) -> f64 {
    let sr = audio.rate as f64;
    let ch = audio.channels.max(1) as usize;
    let mut filters: Vec<(Biquad, Biquad)> =
        (0..ch).map(|_| (Biquad::high_shelf(1681.97, 3.99984, sr), Biquad::high_pass(38.135, 0.5003, sr))).collect();
    let segment = ((sr * 0.1) as usize).max(1);
    let mut segments = Vec::new();
    let mut sum = 0.0;
    let mut n = 0;
    for frame in audio.samples.chunks_exact(ch) {
        for (c, x) in frame.iter().enumerate() {
            let (shelf, hp) = &mut filters[c];
            let k = hp.process(shelf.process(*x as f64));
            sum += k * k;
        }
        n += 1;
        if n == segment {
            segments.push(sum / n as f64);
            sum = 0.0;
            n = 0;
        }
    }
    let blocks: Vec<f64> = segments.windows(4).map(|w| w.iter().sum::<f64>() / 4.0).filter(|e| lufs(*e) > -70.0).collect();
    if blocks.is_empty() {
        return f64::NEG_INFINITY;
    }
    let gate = lufs(blocks.iter().sum::<f64>() / blocks.len() as f64) - 10.0;
    let gated: Vec<f64> = blocks.into_iter().filter(|e| lufs(*e) > gate).collect();
    if gated.is_empty() { f64::NEG_INFINITY } else { lufs(gated.iter().sum::<f64>() / gated.len() as f64) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(amp: f32, seconds: f64) -> Vec<f32> {
        let n = (48000.0 * seconds) as usize;
        (0..n)
            .flat_map(|i| {
                let x = amp * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / 48000.0).sin();
                [x, x]
            })
            .collect()
    }

    #[test]
    fn a_1k_tone_at_minus_20_reads_minus_20() {
        let mut samples = tone(0.1, 4.0);
        // Quiet passages under the relative gate do not pull it down.
        samples.extend(tone(0.001, 4.0));
        let l = integrated(&Audio { rate: 48000, channels: 2, samples });
        assert!((l + 20.0).abs() < 0.5, "{l}");
        assert_eq!(integrated(&Audio { rate: 48000, channels: 2, samples: vec![0.0; 96000] }), f64::NEG_INFINITY);
    }
}
