//! WAV files: reading what `rive --render-audio` writes (32-bit float) and
//! writing the formats `partition render` offers.

use anyhow::{Result, bail};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Pcm16,
    Float32,
}

#[derive(Debug, Clone)]
pub struct Audio {
    pub rate: u32,
    pub channels: u16,
    /// Interleaved samples.
    pub samples: Vec<f32>,
}

impl Audio {
    pub fn frames(&self) -> usize {
        self.samples.len() / self.channels.max(1) as usize
    }

    pub fn seconds(&self) -> f64 {
        self.frames() as f64 / self.rate as f64
    }

    /// Drops the first `frames` frames.
    pub fn skip(&mut self, frames: usize) {
        let n = (frames * self.channels as usize).min(self.samples.len());
        self.samples.drain(..n);
    }

    /// Keeps the first `frames` frames.
    pub fn truncate(&mut self, frames: usize) {
        let n = frames.min(self.frames()) * self.channels as usize;
        self.samples.truncate(n);
    }

    /// The frame after the last one louder than `floor`, never before `keep` frames.
    pub fn end_of_sound(&self, keep: usize, floor: f32) -> usize {
        let ch = self.channels.max(1) as usize;
        let mut end = self.frames();
        while end > keep {
            let frame = &self.samples[(end - 1) * ch..end * ch];
            if frame.iter().any(|s| s.abs() > floor) {
                break;
            }
            end -= 1;
        }
        end
    }
}

fn u16_at(b: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([b[i], b[i + 1]])
}

fn u32_at(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

pub fn read(bytes: &[u8]) -> Result<Audio> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        bail!("not a WAV file");
    }
    let mut i = 12;
    let mut fmt: Option<(u16, u16, u32, u16)> = None;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let size = u32_at(bytes, i + 4) as usize;
        let body = i + 8;
        let end = (body + size).min(bytes.len());
        if id == b"fmt " && size >= 16 {
            let mut tag = u16_at(bytes, body);
            if tag == 0xFFFE && size >= 26 {
                tag = u16_at(bytes, body + 24); // WAVE_FORMAT_EXTENSIBLE: the sub-format
            }
            fmt = Some((tag, u16_at(bytes, body + 2), u32_at(bytes, body + 4), u16_at(bytes, body + 14)));
        } else if id == b"data" {
            let Some((tag, channels, rate, bits)) = fmt else { bail!("WAV data before its format") };
            let data = &bytes[body..end];
            let samples = match (tag, bits) {
                (3, 32) => data.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect(),
                (1, 16) => data.as_chunks::<2>().0.iter().map(|c| i16::from_le_bytes(*c) as f32 / 32768.0).collect(),
                _ => bail!("unsupported WAV encoding (format {tag}, {bits} bits)"),
            };
            return Ok(Audio { rate, channels, samples });
        }
        i = body + size + (size & 1);
    }
    bail!("WAV file without data")
}

pub fn write(audio: &Audio, format: Format) -> Vec<u8> {
    let (tag, bits): (u16, u16) = match format {
        Format::Pcm16 => (1, 16),
        Format::Float32 => (3, 32),
    };
    let bytes_per_sample = bits as u32 / 8;
    let data_len = audio.samples.len() as u32 * bytes_per_sample;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&tag.to_le_bytes());
    out.extend_from_slice(&audio.channels.to_le_bytes());
    out.extend_from_slice(&audio.rate.to_le_bytes());
    out.extend_from_slice(&(audio.rate * audio.channels as u32 * bytes_per_sample).to_le_bytes());
    out.extend_from_slice(&(audio.channels * bits / 8).to_le_bytes());
    out.extend_from_slice(&bits.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in &audio.samples {
        match format {
            Format::Float32 => out.extend_from_slice(&s.to_le_bytes()),
            Format::Pcm16 => {
                let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_both_formats() {
        let audio = Audio { rate: 48000, channels: 2, samples: vec![0.0, 0.5, -0.5, 1.0, 0.25, -1.0] };
        let f = read(&write(&audio, Format::Float32)).unwrap();
        assert_eq!(f.samples, audio.samples);
        assert_eq!((f.rate, f.channels, f.frames()), (48000, 2, 3));
        let p = read(&write(&audio, Format::Pcm16)).unwrap();
        for (a, b) in p.samples.iter().zip(&audio.samples) {
            assert!((a - b).abs() < 1e-4);
        }
    }

    #[test]
    fn trims_trailing_silence_but_not_before_keep() {
        let audio = Audio { rate: 10, channels: 1, samples: vec![0.0, 0.3, 0.0, 0.0, 0.0] };
        assert_eq!(audio.end_of_sound(0, 1e-4), 2);
        assert_eq!(audio.end_of_sound(4, 1e-4), 4);
        let mut skipped = audio.clone();
        skipped.skip(1);
        assert_eq!(skipped.samples, [0.3, 0.0, 0.0, 0.0]);
        skipped.skip(10);
        assert!(skipped.samples.is_empty());
        assert!(read(b"nope").is_err());
    }
}
