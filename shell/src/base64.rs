//! Base64, which carries binary song files (samples) inside bundles and the
//! app's text files. Encoded in lines of 76 characters, as the app writes it.

use anyhow::{Result, bail};

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// `bytes` as base64, in lines of 76 characters, each ending with a newline.
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 4 / 3 + bytes.len() / 57 + 4);
    let mut line = 0;
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
        line += 4;
        if line >= 76 {
            out.push('\n');
            line = 0;
        }
    }
    if line > 0 {
        out.push('\n');
    }
    out
}

/// Decodes base64, skipping whitespace; '=' ends the data.
pub fn decode(text: &str) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut bits = 0;
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => break,
            b' ' | b'\n' | b'\r' | b'\t' => continue,
            _ => bail!("'{}' is not a base64 character", c as char),
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_wraps() {
        for n in 0..200 {
            let bytes: Vec<u8> = (0..n).map(|i| (i * 37 + 11) as u8).collect();
            let text = encode(&bytes);
            assert!(text.lines().all(|l| l.len() <= 76));
            assert_eq!(decode(&text).unwrap(), bytes);
        }
        assert_eq!(encode(&[0, 61, 122, 183, 244]), "AD16t/Q=\n");
        assert!(decode("AD!6").is_err());
    }
}
