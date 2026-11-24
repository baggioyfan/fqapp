//! x-gorgon 8404 scheme. Legacy/dead for the current upstream but still
//! requested while a device registers.

use md5::{Digest, Md5};
use rand::Rng;

/// The playback/enrollment x-gorgon variant.
///
/// Ported from `Amor5207/lvguo-tv` v2.0.8 (commit `32fcdfdb`),
/// `web/internal/sign/sign.go::gorgon`. Its KSA/PRGA intentionally differ from
/// the legacy signer below: the KSA assigns `s[i] = s[j]` instead of swapping,
/// and that quirk is part of the accepted wire output.
pub(crate) fn generate_v5_gorgon(query: &str, body: &[u8], ts: u32, nonce: u16) -> String {
    let mut data = Vec::with_capacity(20);
    data.extend_from_slice(&Md5::digest(query.as_bytes())[..4]);
    data.extend_from_slice(&Md5::digest(body)[..4]);
    data.extend_from_slice(&[0u8; 4]);
    data.extend_from_slice(&67503104u32.to_le_bytes());
    data.extend_from_slice(&ts.to_be_bytes());

    let key = [
        0x4a,
        0x40,
        0x16,
        (nonce >> 8) as u8,
        0x47,
        0x6c,
        1,
        nonce as u8,
    ];
    let mut table = [0u8; 256];
    for (index, value) in table.iter_mut().enumerate() {
        *value = index as u8;
    }
    let mut j = 0usize;
    for index in 0..256 {
        j = (j + table[index] as usize + key[index % 8] as usize) & 255;
        table[index] = table[j];
    }

    j = 0;
    for index in 0..data.len() {
        j = (j + table[index + 1] as usize) & 255;
        let value = table[j];
        table[index + 1] = value;
        data[index] ^= table[(value as usize * 2) & 255];
    }

    // In-place mutation matters: the final iteration reads the already-written
    // first byte as its `next` value, exactly like the reference loop.
    for index in 0..data.len() {
        let value = data[index].rotate_left(4);
        let next = data.get(index + 1).copied().unwrap_or(data[0]);
        data[index] = !((next ^ value).reverse_bits() ^ 20);
    }

    let mut out = String::with_capacity(6 + data.len() * 2);
    out.push_str("8404");
    for byte in [nonce as u8, (nonce >> 8) as u8, 0x40, 1] {
        out.push_str(&format!("{byte:02x}"));
    }
    for byte in data {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

// The `(x | x)` / `(x & x)` pair below is intentionally kept: it is dead
// arithmetic that the upstream scheme carries, and changing it would change
// the emitted bytes, so the lint is silenced deliberately rather than "fixed".
#[allow(clippy::eq_op)]
pub fn generate_x_gorgon(param: &str) -> String {
    let ts = crate::timeutil::now_secs();
    let time_bytes = (ts as u32).to_be_bytes();

    let mut hasher = Md5::new();
    hasher.update(param.as_bytes());
    let sum = hasher.finalize();
    let md5_prefix = &sum[..4];

    let mut data: Vec<u8> = Vec::with_capacity(16);
    data.extend_from_slice(md5_prefix);
    data.extend_from_slice(&[0, 0, 0, 0, 0, 1, 7, 4]);
    data.extend_from_slice(&time_bytes);

    let mut table: Vec<i64> = (0..256i64).collect();

    let rnd: [u8; 2] = rand::thread_rng().gen();
    let r1 = rnd[0] as i64;
    let r2 = rnd[1] as i64;
    let key = [74i64, 0, 22, r2, 71, 108, 0, r1];

    let mut j: i64 = 0;
    for i in 0..256usize {
        j = (j + table[i] + key[i & 7]) & 0xFFFF_FFFF;
        j &= 255;
        table[i] = table[j as usize];
    }

    let dlen = data.len();
    let mut k: i64 = 0;
    for i in 1..=dlen {
        let idx = ((((i as i64 - 1) ^ 1) + ((i as i64 - 1) & 1)) << 1) & 255;
        let idx = idx as usize;

        let table_val = table[idx];
        let xor_val = k ^ table_val;
        k = (((k | table_val) << 1) - xor_val) & 0xFFFF_FFFF;

        let idx2 = (k & 255) as usize;
        let table_val2 = table[idx2];
        table[idx] = table_val2;
        table[idx2] = table_val2;

        let enc_idx = ((table_val2 | table_val2) + (table_val2 & table_val2)) & 255;
        data[i - 1] = ((data[i - 1] as i64) ^ table[enc_idx as usize]) as u8;
    }

    const W2: i64 = 0xFFFF_FFAA;
    const W3: i64 = 85;
    const W4: i64 = 51;
    let len_inv = (!(dlen as i64)) & 0xFFFF_FFFF;

    for i in 1..=dlen {
        let mut val = data[i - 1] as i64;

        val = ((val >> 4) & 15) | ((val & 15) << 4);
        data[i - 1] = (val & 255) as u8;

        if i == dlen {
            data[i - 1] = (val ^ (data[0] as i64)) as u8;
        } else {
            let next = data[i] as i64;
            data[i - 1] = ((val | next) - (val & next)) as u8;
        }

        let mut val = data[i - 1] as i64;

        let t1 = W2 & (val << 1);
        let t2 = W3 & (val >> 1);
        val = t1 | t2;

        let t3 = val << 2;
        let t4 = W4 & (val >> 2);
        let mut mix = (t3 & 0xFFFF_FFCF) | t4;

        let high = (mix >> 4) & 15;
        let low = mix & 268_435_455;
        mix = (low << 4) | high;

        val = mix ^ len_inv;
        data[i - 1] = (val & 255) as u8;
    }

    let mut out: Vec<u8> = Vec::with_capacity(6 + data.len());
    out.extend_from_slice(&[132, 4, rnd[0], rnd[1], 0, 0]);
    out.extend_from_slice(&data);
    hex::encode(out)
}
