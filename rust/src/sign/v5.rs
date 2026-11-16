//! v5 (04.10.03) playback signing.
//!
//! The upstream turned off its old playback address endpoints on 2026-11-16
//! afternoon: both `POST /novel/player/multi_video_model/v1/` and
//! `GET /reading/bookapi/video_tab/multi_video_model/v1/` now answer
//! `HTTP 200` with a **zero-byte body** (`server: volc-dcdn`, a silent block).
//! Registration still works, which is why the symptom is "identities are
//! issued, addresses cannot be fetched".
//!
//! The replacement is `POST /novel/player/multi_video_model/player/v1`, whose
//! body is gzip-compressed JSON and whose headers carry only three signature
//! headers: `x-khronos`, `x-helios`, `x-medusa`.
//!
//! Ported from hongguoTV `Signer.kt` / `AesV3.kt` / `V5Playback.kt`
//! (GPL-3.0-only, itself derived from drpys), same licence as this crate.
//! Byte order, table order and wire constants are reproduced verbatim; do not
//! "clean up" the index juggling in [`hash_f13_v5`] — it is transcribed from a
//! reference implementation, not designed here.

use std::sync::OnceLock;

use base64::Engine as _;
use md5::{Digest, Md5};
use rand::Rng;

use super::sm3::sm3_hash;
use super::v5_tables::{HASH_TABLE, SBOX_HEX};

/// v5 wire constants.
const MAGIC_HEX: &str = "2d4b4fca49750d433fb5ae2c226dcc56";
const SIGN_KEY_HEX: &str = "b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d";
/// Licence number embedded in `x-medusa` and `x-helios` for the v5 protocol.
pub const V5_LICENSE: &str = "646637794";
/// User agent the upstream expects on the playback door. It must be applied
/// *after* the signature headers, otherwise their own UA wins.
pub const V5_UA: &str =
    "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)";

const BASE64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

fn le32(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

fn be32(v: u32) -> [u8; 4] {
    v.to_be_bytes()
}

fn le64(v: u64) -> [u8; 8] {
    v.to_le_bytes()
}

fn md5_bytes(data: &[u8]) -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(data);
    let out = hasher.finalize();
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&out);
    buf
}

fn md5_hex_upper(data: &[u8]) -> String {
    hex::encode_upper(md5_bytes(data))
}

fn parse_hex(value: &str) -> Vec<u8> {
    hex::decode(value).expect("v5 constant is valid hex")
}

fn rand_u32() -> u32 {
    rand::thread_rng().gen()
}

/// Process nonce: one random 18-byte value per cold start, base64url without
/// padding (24 chars). It is embedded in the v5 device proto.
fn process_nonce() -> &'static str {
    static NONCE: OnceLock<String> = OnceLock::new();
    NONCE.get_or_init(|| {
        let mut bytes = [0u8; 18];
        rand::thread_rng().fill(&mut bytes);
        BASE64_NO_PAD.encode(bytes)
    })
}

/// Process start time in milliseconds, embedded in the v5 device proto.
fn process_started_ms() -> i64 {
    static STARTED: OnceLock<i64> = OnceLock::new();
    *STARTED.get_or_init(chrono_now_millis)
}

/// Wall clock in milliseconds. Kept in one place so the probe can freeze it.
pub fn chrono_now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

const BASE64_NO_PAD: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::URL_SAFE_NO_PAD;

// ---------------------------------------------------------------------------
// Protobuf (encode-only): sint / float / bytes. Field order is call order,
// which matters because the signature covers these exact bytes.
// ---------------------------------------------------------------------------

pub enum Field {
    /// Zigzag varint (`sint`), the encoding every v5 numeric field uses.
    Sint(i64),
    /// Length-delimited payload: strings and nested messages alike.
    Bytes(Vec<u8>),
    /// Fixed32 little-endian float.
    Float(f32),
}

fn varint(mut value: u64, out: &mut Vec<u8>) {
    while value > 127 {
        out.push(((value & 127) as u8) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}

fn zigzag(n: i64) -> u64 {
    if n < 0 {
        (n.wrapping_neg() as u64) * 2 - 1
    } else {
        (n as u64) * 2
    }
}

/// Encodes fields in the order given. Empty byte payloads are skipped, exactly
/// like the reference writer.
pub fn proto(fields: &[(u32, Field)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (tag, field) in fields {
        match field {
            Field::Sint(n) => {
                varint((*tag as u64) << 3, &mut out);
                varint(zigzag(*n), &mut out);
            }
            Field::Float(value) => {
                varint(((*tag as u64) << 3) | 5, &mut out);
                out.extend_from_slice(&value.to_le_bytes());
            }
            Field::Bytes(data) => {
                if data.is_empty() {
                    continue;
                }
                varint(((*tag as u64) << 3) | 2, &mut out);
                varint(data.len() as u64, &mut out);
                out.extend_from_slice(data);
            }
        }
    }
    out
}

fn s(tag: u32, value: &str) -> (u32, Field) {
    (tag, Field::Bytes(value.as_bytes().to_vec()))
}

// ---------------------------------------------------------------------------
// hash_f13 — the branch/hash primitive shared by the signatures
// ---------------------------------------------------------------------------

fn get_iv(initial: u32, data: &[u8]) -> u32 {
    let mut value = initial;
    for (i, byte) in data.iter().enumerate() {
        value = if i & 1 == 0 {
            (value >> 4) ^ value ^ value.wrapping_shl(6) ^ (*byte as u32)
        } else {
            !((value >> 7) ^ value ^ ((*byte as u32) | value.wrapping_shl(12)))
        };
    }
    value
}

fn iv(query: &[u8], body: &[u8], ts: i32) -> u32 {
    let step = get_iv(0x2023_0928, query);
    let step = get_iv(step, body);
    get_iv(step, &le32(ts as u32))
}

/// `sumMd5` fold over the first 12 bytes.
fn sum_md5(data: &[u8]) -> u32 {
    let mut check: u32 = 0x2022_0420;
    for (i, &byte) in data.iter().take(12).enumerate() {
        let shift = if i & 1 == 0 { 3 } else { 5 };
        let temp = (check >> shift) ^ check;
        check = if i & 1 == 0 {
            (byte as u32) ^ check.wrapping_shl(7)
        } else {
            !((byte as u32) | check.wrapping_shl(11))
        };
        check ^= temp;
    }
    (check | 4) ^ 0x0100_0000
}

/// The v5 hash: branch 12 only, dedicated `ivV1` and a 0x20 tag byte.
///
/// `query` is the SM3 of the request query string and `body_md5` the MD5 of the
/// bytes actually sent (gzip-compressed for the v5 door). Callers must have
/// already steered the request ticket so that `(iv & 15) == 12`; see
/// [`branch_v5`].
pub fn hash_f13_v5(query: &[u8], body_md5: &[u8], ts: i32) -> [u8; 20] {
    let raw_iv = iv(query, body_md5, ts);
    debug_assert_eq!(
        raw_iv & 15,
        12,
        "v5 hash branch must be 12; adjust _rticket before signing"
    );
    const CHOSEN: [usize; 11] = [96, 1, 3, 4, 0, 6, 5, 2, 0, 7, 7];
    hash_f13_core(query, body_md5, ts, 0x9d4a_97c2, &CHOSEN, 0x20)
}

/// The shared F13 core. `iv_v1`, the round schedule and the tag byte are the
/// only per-protocol inputs; everything else is the same rotation network.
fn hash_f13_core(
    query: &[u8],
    body_md5: &[u8],
    ts: i32,
    iv_v1: u32,
    chosen: &[usize; 11],
    tag: u32,
) -> [u8; 20] {
    let count = iv_v1.wrapping_add(ts as u32);

    let table: Vec<u32> = HASH_TABLE
        .iter()
        .map(|entry| (*entry as u32).rotate_right((count.wrapping_add(1)) & 255))
        .collect();

    let shift = count.wrapping_add(2) & 7;
    let mut pad = [0u8; 4];
    for (i, value) in [0xfa_u32, 0x45, 0x61, 0xd7].iter().enumerate() {
        pad[i] = ((value | (value << 8)) >> shift) as u8;
    }

    let mut data = Vec::with_capacity(query.len() + body_md5.len() + 16);
    data.extend_from_slice(query);
    data.extend_from_slice(body_md5);
    data.extend_from_slice(&le32(ts as u32));
    data.extend_from_slice(&pad);
    data.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0x01, 0xa0]);

    let mut di: Vec<u32> = data
        .as_chunks::<4>()
        .0
        .iter()
        .map(|c| u32::from_be_bytes(*c))
        .collect();

    for i in 0..112 {
        let x = di[i + 1];
        let y = di[i + 14];
        let value = di[i]
            .wrapping_add(di[i + 9])
            .wrapping_add(x.rotate_left(14) ^ x.rotate_left(25) ^ (x >> 3))
            .wrapping_add(y.rotate_left(13) ^ y.rotate_left(15) ^ (y >> 10));
        di.push(value);
    }

    let initial: Vec<u32> = [
        0x7aba_4fc8_u32,
        0x6716_6507,
        0x6403_fa00,
        0x340f_512f,
        984_304_912,
        3_005_047_866,
        2_874_125_293,
        2_152_413_264,
    ]
    .iter()
    .map(|value| value.rotate_right(count))
    .collect();

    let mut d: Vec<u32> = initial.clone();

    for i in 0..chosen[0] {
        let base = iv_v1.wrapping_add(i as u32);
        let n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]];
        let x = d[chosen[1]];
        let n2 = x.rotate_left(26) ^ x.rotate_left(21) ^ x.rotate_left(7);
        let n4 = di[(base & 127) as usize]
            .wrapping_add(n1)
            .wrapping_add(n2)
            .wrapping_add(table[(base & 63) as usize])
            .wrapping_add(d[chosen[5]]);
        let y = d[chosen[2]];
        let n5 = y.rotate_left(30) ^ y.rotate_left(19) ^ y.rotate_left(10);
        let n6 = (y & d[chosen[6]]) | ((y | d[chosen[6]]) & d[chosen[7]]);
        let old = d[chosen[9]];
        let moved = d.remove(7);
        d.insert(0, moved);
        d[chosen[10]] = n5.wrapping_add(n6).wrapping_add(n4);
        d[chosen[8]] = old.wrapping_add(n4);
    }

    let mut ret = Vec::with_capacity(32);
    for i in 0..8 {
        ret.extend_from_slice(&be32(d[i].wrapping_add(initial[i])));
    }

    let mut folded = [0u8; 16];
    for i in 0..16 {
        folded[i] = ret[i] ^ ret[i + 16];
    }

    let mut out = [0u8; 20];
    out[..16].copy_from_slice(&folded);
    out[16..].copy_from_slice(&le32(sum_md5(&folded) | tag));
    out
}

/// Branch selector: 0 means "this ticket produces a signable v5 request".
pub fn branch_v5(query: &str, body: Option<&[u8]>, ts: i32) -> u32 {
    let query_sm3 = sm3_hash(query.as_bytes());
    let body_md5 = body.map(md5_bytes).unwrap_or([0u8; 16]);
    let raw = iv(&query_sm3, &body_md5, ts) & 15;
    if raw == 12 {
        0
    } else {
        1
    }
}

// ---------------------------------------------------------------------------
// xmxor — byte diffusion applied to the medusa plaintext
// ---------------------------------------------------------------------------

fn xmxor(data: &[u8], key: &[u8]) -> Vec<u8> {
    let n = data.len();
    assert!(n >= 4, "xmxor needs at least four bytes");
    let mut encoded = vec![0u32; n];

    for i in 0..n {
        let at = (i * 4) & 28;
        let d0 = key[at] as u32;
        let d1 = key[at + 1] as u32;
        let v = data[i] as u32;
        let mut d2 = (((v << 4) | (v >> 4)) & 255) + d0;
        d2 = (!d2) ^ d1;
        let masked = d2 & 255;
        d2 = ((masked << 3) | (masked >> 5)) & 255;
        d2 = (d2 + d1) & 255;
        d2 = (d2 ^ d0) & 255;
        encoded[n - i - 1] = (!d2) & 255;
    }

    let last = encoded[n - 1] ^ encoded[n - 2];
    let first = encoded[0];
    encoded[0] = ((!last).wrapping_add(first)) & 255;
    encoded[1] = ((encoded[0] ^ encoded[n - 1] ^ 254).wrapping_add(encoded[1])) & 255;
    encoded[2] = (encoded[2].wrapping_add(
        (last.wrapping_sub(first)) ^ (((encoded[1] << 3) | (encoded[1] >> 5)) & 255) ^ 2,
    )) & 255;

    for i in 0..n - 4 {
        let temp = (((encoded[i + 2] << 3) | (encoded[i + 2] >> 5)) & 255)
            ^ encoded[i + 1]
            ^ ((i as u32) + 3);
        encoded[i + 3] = ((!temp).wrapping_add(encoded[i + 3])) & 255;
    }

    encoded[n - 1] ^= encoded[n - 2];
    let sum: u32 = encoded[1..].iter().fold(0u32, |a, b| a.wrapping_add(*b));
    encoded[0] = ((encoded[0] ^ encoded[1]).wrapping_add(sum)) & 255;

    encoded.iter().map(|value| *value as u8).collect()
}

// ---------------------------------------------------------------------------
// AesV3 — protocol-specific block transform, not standard AES
// ---------------------------------------------------------------------------

struct AesV3 {
    v5: bool,
    sbox: Vec<u32>,
    con: [usize; 4],
    order: [usize; 16],
    keys: Vec<[u32; 4]>,
}

impl AesV3 {
    /// `sbox` is the protocol's 1024-byte box (v5 ships its own, v3 has
    /// another). Only the v5 door is signed in production; the v3 tables exist
    /// so the shared machinery stays verifiable against published vectors.
    fn new(key: &[u8], ts: i32, v5: bool, sbox_all: &[u8]) -> Self {
        assert_eq!(key.len(), 16, "AesV3 key is 16 bytes");
        assert_eq!(sbox_all.len(), 1024, "sbox is 1024 bytes");
        let word = (ts & 3) as usize;

        let sbox: Vec<u32> = sbox_all[word * 256..(word + 1) * 256]
            .iter()
            .map(|byte| *byte as u32)
            .collect();

        let con_table: [[usize; 4]; 4] = if v5 {
            [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]]
        } else {
            [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]]
        };
        let order_table: [[usize; 16]; 4] = if v5 {
            [
                [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
                [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
                [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7],
            ]
        } else {
            [
                [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
                [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
                [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
            ]
        };
        let initial_table: [u32; 4] = if v5 {
            [0xbbb5_de72, 0xd463_8d5b, 0x92a5_f73b, 0x89f8_a1c9]
        } else {
            [0xca02_5ddc, 0x823d_c546, 0xc942_0583, 0xc298_225f]
        };
        let initial = initial_table[word];

        // xor(le32(initial) * 4, key) followed by 32 zero bytes, read as words.
        let mut expanded_bytes = Vec::with_capacity(48);
        for _ in 0..4 {
            expanded_bytes.extend_from_slice(&le32(initial));
        }
        for i in 0..16 {
            expanded_bytes[i] ^= key[i];
        }
        expanded_bytes.extend_from_slice(&[0u8; 32]);

        let mut expanded: Vec<u32> = expanded_bytes.iter().map(|byte| *byte as u32).collect();
        let mut rounds: u32 = 8;
        for i in 4..12 {
            let at = 4 * (i - 1);
            let mut a = expanded[at];
            let mut b = expanded[at + 1];
            let mut c = expanded[at + 2];
            let mut d = expanded[at + 3];
            if i & 3 == 0 {
                let t = ((initial >> (rounds & 24)) ^ sbox[b as usize]) & 255;
                b = sbox[c as usize];
                c = sbox[d as usize];
                d = sbox[a as usize];
                a = t;
            }
            rounds += 2;
            expanded[at + 4] = a ^ expanded[at - 12];
            expanded[at + 5] = b ^ expanded[at - 11];
            expanded[at + 6] = c ^ expanded[at - 10];
            expanded[at + 7] = d ^ expanded[at - 9];
        }

        let mut keys = Vec::with_capacity(12);
        for i in 0..12 {
            let slice = &expanded[i * 4..i * 4 + 4];
            keys.push([slice[0], slice[1], slice[2], slice[3]]);
        }

        AesV3 {
            v5,
            sbox,
            con: con_table[word],
            order: order_table[word],
            keys,
        }
    }

    fn block(&self, value: &[u8; 16]) -> [u8; 16] {
        let mut rows = [[0u32; 4]; 4];
        for (i, row) in rows.iter_mut().enumerate() {
            for (j, cell) in row.iter_mut().enumerate() {
                *cell = value[i * 4 + j] as u32;
            }
        }

        // Round-key mixing: one `con` permutation per column, offset selects the
        // round's four key rows.
        let add_con = |rows: &mut [[u32; 4]; 4], offset: usize| {
            for (i, row) in rows.iter_mut().enumerate() {
                for (j, cell) in row.iter_mut().enumerate() {
                    *cell ^= self.keys[offset + i][self.con[j]];
                }
            }
        };

        add_con(&mut rows, 0);

        for round in 1..=2 {
            for row in rows.iter_mut() {
                for cell in row.iter_mut() {
                    *cell = self.sbox[*cell as usize];
                }
            }

            let before = rows;
            for (row, &source) in rows.iter_mut().zip(self.con.iter()) {
                *row = before[source];
            }

            let flat: Vec<u32> = rows.iter().flatten().copied().collect();
            for (cell, &at) in rows.iter_mut().flatten().zip(self.order.iter()) {
                *cell = flat[at];
            }

            if round == 1 {
                for row in rows.iter_mut() {
                    let old = *row;
                    *row = [
                        old[self.con[0]],
                        old[self.con[1]],
                        old[self.con[2]],
                        old[self.con[3]],
                    ];
                }

                let xt = |x: u32| ((x << 1) ^ if x & 128 != 0 { 0x1b } else { 0 }) & 255;
                let [r0, r1, r2, r3] = &mut rows;
                for i in 0..4 {
                    let t = r0[i] ^ r1[i] ^ r2[i] ^ r3[i];
                    let u = r0[i];
                    r0[i] ^= t ^ xt(r0[i] ^ r1[i]);
                    r1[i] ^= t ^ xt(r1[i] ^ r2[i]);
                    r2[i] ^= t ^ xt(r2[i] ^ r3[i]);
                    r3[i] ^= t ^ xt(r3[i] ^ u);
                }
            }

            add_con(&mut rows, round * 4);
        }

        for (i, row) in rows.iter_mut().enumerate() {
            for (j, cell) in row.iter_mut().enumerate() {
                *cell ^= self.keys[4 + i][j];
            }
        }

        let mut out = [0u8; 16];
        for (cell, &value) in out.iter_mut().zip(rows.iter().flatten()) {
            *cell = value as u8;
        }
        out
    }

    /// Encrypts in place-ish: the first 248 bytes carry the bit shuffles, the
    /// remainder is passed through unchanged, and one byte is prepended.
    fn encrypt(&self, source: &[u8], iv: &[u8]) -> Vec<u8> {
        assert!(
            source.len() >= 248,
            "AesV3 input must be at least 248 bytes"
        );
        assert_eq!(iv.len(), 16, "AesV3 iv is 16 bytes");

        let (wire, compact): ([usize; 8], [usize; 8]) = if self.v5 {
            ([6, 5, 3, 4, 2, 7, 1, 0], [1, 7, 3, 6, 2, 0, 4, 5])
        } else {
            ([5, 6, 2, 4, 3, 1, 0, 7], [1, 6, 0, 7, 2, 4, 5, 3])
        };

        let mut plaintext = [0u8; 32];
        for i in 0..31 {
            for j in 0..8 {
                let bit = (source[i * 8 + j] >> wire[j]) & 1;
                plaintext[i] |= bit << compact[j];
            }
        }
        plaintext[31] = 1;

        let mut head = [0u8; 16];
        for i in 0..16 {
            head[i] = plaintext[i] ^ iv[i];
        }
        let first = self.block(&head);

        let mut tail = [0u8; 16];
        for i in 0..16 {
            tail[i] = plaintext[16 + i] ^ first[i];
        }
        let second = self.block(&tail);

        let mut key = [0u8; 32];
        key[..16].copy_from_slice(&first);
        key[16..].copy_from_slice(&second);

        let mut out = source.to_vec();
        for (i, byte) in key.iter().take(31).enumerate() {
            for j in 0..8 {
                let at = i * 8 + j;
                let bit = (byte >> compact[j]) & 1;
                out[at] = (out[at] & !(1u8 << wire[j])) | (bit << wire[j]);
            }
        }

        let mut result = Vec::with_capacity(out.len() + 1);
        result.push(key[31]);
        result.extend_from_slice(&out);
        result
    }
}

// ---------------------------------------------------------------------------
// x-helios
// ---------------------------------------------------------------------------

pub fn helios_v5(ts: i32, random: u32) -> String {
    helios_with_license(ts, random, V5_LICENSE)
}

/// The v3 licence number, kept so the shared rotation core can be validated
/// against the reference project's published vectors.
#[cfg(test)]
const V3_LICENSE: &str = "1588093228";

fn helios_with_license(ts: i32, random: u32, license: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(le32(random));
    hasher.update(b"8662");
    let digest = hasher.finalize();
    // The reference hexes the digest and then treats the 32 ASCII bytes as
    // four little-endian u64 words.
    let ascii = hex::encode(digest);
    let bytes = ascii.as_bytes();

    let mut words: Vec<u64> = (0..4)
        .map(|k| {
            let mut buf = [0u8; 8];
            buf.copy_from_slice(&bytes[k * 8..k * 8 + 8]);
            u64::from_le_bytes(buf)
        })
        .collect();

    let mut table: Vec<u64> = vec![words[0]];
    let mut b0 = words.remove(0);
    let mut b8 = words.remove(0);

    for i in 0..34u64 {
        let mut x8 = b8.rotate_right(8).wrapping_add(b0) ^ i;
        words.push(x8);
        x8 ^= b0.rotate_right(61);
        table.push(x8);
        b0 = x8;
        b8 = words.remove(0);
    }

    let text = format!("{ts}-{license}-8662");
    let text_bytes = text.as_bytes();
    let padding = 16 - text_bytes.len() % 16;
    let mut data = text_bytes.to_vec();
    data.extend(std::iter::repeat_n(padding as u8, padding));

    let mut output: Vec<u8> = le32(random).to_vec();
    for at in (0..data.len()).step_by(16) {
        let mut a = u64::from_le_bytes(data[at..at + 8].try_into().unwrap());
        let mut b = u64::from_le_bytes(data[at + 8..at + 16].try_into().unwrap());
        for entry in table.iter().take(34) {
            b = *entry ^ a.wrapping_add(b.rotate_right(8));
            a = b ^ a.rotate_right(61);
        }
        output.extend_from_slice(&le64(a));
        output.extend_from_slice(&le64(b));
    }

    BASE64.encode(output)
}

// ---------------------------------------------------------------------------
// Identity carried by a v5 playback request
// ---------------------------------------------------------------------------

/// The identity a v5 request carries. Every field also appears in the query
/// string; the two have to agree or the upstream drops the response.
#[derive(Debug, Clone)]
pub struct V5Identity<'a> {
    pub device_id: &'a str,
    pub iid: &'a str,
    pub cdid: &'a str,
    pub version_name: &'a str,
    pub os_version: &'a str,
    pub device_type: &'a str,
    pub channel: &'a str,
}

impl Default for V5Identity<'_> {
    fn default() -> Self {
        V5Identity {
            device_id: "",
            iid: "",
            cdid: "",
            version_name: "7.4.3.32",
            os_version: "12",
            device_type: "PGT-AN10",
            channel: "vivo_8662_64",
        }
    }
}

// ---------------------------------------------------------------------------
// x-medusa (v5)
// ---------------------------------------------------------------------------

pub fn medusa_v5(url: &str, body: Option<&[u8]>, ts: i32, who: &V5Identity) -> String {
    medusa_v5_with(
        url,
        body,
        ts,
        who,
        rand_u32(),
        rand_u32(),
        rand_u32(),
        process_nonce(),
        process_started_ms(),
    )
}

/// Deterministic inner form: every random input is a parameter, so the value
/// can be compared against an independent implementation.
#[allow(clippy::too_many_arguments)]
fn medusa_v5_with(
    url: &str,
    body: Option<&[u8]>,
    ts: i32,
    who: &V5Identity,
    nonce: u32,
    packed_rand: u32,
    message_rand: u32,
    process_nonce: &str,
    process_started: i64,
) -> String {
    let query_raw = url.split_once('?').map(|(_, q)| q).unwrap_or("");
    let query = sm3_hash(query_raw.as_bytes());
    let body_md5 = body.map(md5_bytes).unwrap_or([0u8; 16]);
    let f13 = hash_f13_v5(&query, &body_md5, ts);
    let flags = [0u8; 8];
    let started = process_started;

    let device_info = proto(&[
        (1, Field::Sint(1)),
        (2, Field::Sint(2)),
        s(3, "8662"),
        s(4, who.device_id),
        s(5, process_nonce),
        s(6, "!noperm!"),
        s(12, "Asia/Shanghai,8"),
        s(13, "zh_CN"),
        s(22, who.os_version),
        (25, Field::Sint(started)),
        s(30, who.device_type),
        s(31, "HONOR"),
        s(32, who.device_type),
        s(34, "HONOR"),
    ]);

    let env = proto(&[
        s(6, "v04.10.03.04-bugfix"),
        s(8, who.channel),
        (12, Field::Bytes(device_info)),
        s(14, who.version_name),
    ]);

    let message = proto(&[
        (1, Field::Bytes(parse_hex(MAGIC_HEX))),
        (2, Field::Sint(5)),
        (3, Field::Sint(message_rand as i64)),
        s(4, "8662"),
        s(5, who.device_id),
        s(6, V5_LICENSE),
        s(7, who.version_name),
        s(8, "v04.10.03-ml-android"),
        (9, Field::Sint(0x040a_0300)),
        (10, Field::Bytes(flags.to_vec())),
        (12, Field::Sint(ts as i64)),
        (13, Field::Bytes(f13.to_vec())),
        (14, Field::Bytes(query[..6].to_vec())),
        (
            15,
            Field::Bytes(proto(&[
                (1, Field::Sint(1)),
                (2, Field::Sint(1)),
                (3, Field::Sint(1)),
                (5, Field::Sint(1)),
            ])),
        ),
        (17, Field::Sint(ts as i64)),
        s(20, "none"),
        (21, Field::Sint(377)),
        (23, Field::Bytes(env)),
        s(
            24,
            r#"{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}"#,
        ),
    ]);

    let value = parse_hex(SIGN_KEY_HEX);
    // The xmxor key is derived from the *same* nonce that ends up in `packed` and in the
    // two bytes after `encrypted`; drawing a fresh random here silently breaks the binding
    // between the keystream and the envelope the server checks.
    let mut seed_input = Vec::with_capacity(68);
    seed_input.extend_from_slice(&value);
    seed_input.extend_from_slice(&le32(nonce));
    seed_input.extend_from_slice(&value);
    let hash = sm3_hash(&seed_input);

    let high = (nonce >> 16) & 255;
    let seed_word = ((high.wrapping_shl(11)) | (nonce >> 24)) ^ (high >> 5) ^ high;
    let seed = le32(!seed_word);

    let mut transformed: Vec<u8> = flags.to_vec();
    transformed.extend_from_slice(&xmxor(&message, &hash));
    transformed.reverse();
    for i in 0..transformed.len() {
        transformed[i] ^= seed[3 - (i & 3)];
    }

    let check = 0x1800_0001u32 | (((query[0] as u32) & 63) << 14) | (((f13[0] as u32) & 63) << 8);

    let mut packed = Vec::with_capacity(11 + transformed.len());
    packed.push(0xca);
    packed.extend_from_slice(&le32(packed_rand));
    packed.extend_from_slice(&le32(check));
    packed.extend_from_slice(&transformed);
    packed.push((nonce >> 16) as u8);
    packed.push((nonce >> 24) as u8);

    let aes = AesV3::new(&md5_bytes(&value[..16]), ts, true, &parse_hex(SBOX_HEX));
    let encrypted = aes.encrypt(&packed, &md5_bytes(&value[16..32]));

    let mut prefix = le32(5).to_vec();
    prefix.extend_from_slice(&parse_hex(MAGIC_HEX));
    let ts_bytes = le32(ts as u32);
    for i in 0..prefix.len() {
        prefix[i] ^= ts_bytes[i & 3];
    }

    let mut out = prefix;
    out.push(nonce as u8);
    out.push((nonce >> 8) as u8);
    out.push(0);
    out.push(1);
    out.extend_from_slice(&encrypted);
    BASE64.encode(out)
}

// ---------------------------------------------------------------------------
// Request assembly
// ---------------------------------------------------------------------------

/// Percent-encodes like Java's `URLEncoder` (space as `%20`, `~` preserved).
fn encode_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// The query bag, in the exact order the v5 door expects.
fn playback_query(who: &V5Identity, ticket: i64) -> String {
    let pairs: [(&str, &str); 12] = [
        ("aid", "8662"),
        ("app_name", "novelread"),
        ("version_code", "74332"),
        ("version_name", who.version_name),
        ("channel", who.channel),
        ("device_platform", "android"),
        ("device_type", who.device_type),
        ("os_version", who.os_version),
        ("update_version_code", "74332"),
        ("iid", who.iid),
        ("cdid", who.cdid),
        ("device_id", who.device_id),
    ];
    let mut parts: Vec<String> = pairs
        .iter()
        .map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v)))
        .collect();
    parts.push(format!("_rticket={ticket}"));
    parts.join("&")
}

/// A signed v5 request: URL plus the headers to send with it, in wire order.
pub struct V5Request {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

/// Signs one v5 playback request.
///
/// The v5 hash has a single usable branch (12), so the request ticket is nudged
/// until the query lands on it — that is what the 1024 attempts are for.
pub fn sign_playback_v5(
    base: &str,
    who: &V5Identity,
    body: Option<&[u8]>,
    now_ms: i64,
) -> Option<V5Request> {
    let ts = (now_ms / 1000) as i32;

    for offset in 0..1024 {
        let ticket = now_ms + offset;
        let query = playback_query(who, ticket);
        if branch_v5(&query, body, ts) != 0 {
            continue;
        }

        let url = format!("{base}?{query}");
        let mut headers: Vec<(String, String)> = vec![
            ("x-khronos".to_string(), ts.to_string()),
            ("x-helios".to_string(), helios_v5(ts, rand_u32())),
            ("x-medusa".to_string(), medusa_v5(&url, body, ts, who)),
        ];

        headers.push(("User-Agent".to_string(), V5_UA.to_string()));
        headers.push((
            "Accept".to_string(),
            "application/json; charset=utf-8,application/x-protobuf".to_string(),
        ));
        if let Some(payload) = body {
            headers.push(("Content-Encoding".to_string(), "gzip".to_string()));
            headers.push(("x-ss-stub".to_string(), md5_hex_upper(payload)));
        }

        return Some(V5Request { url, headers });
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// v3 F13 variant, used only to validate the shared core against the
    /// reference project's published vectors (`tests/data/signing.json`).
    pub(super) fn hash_f13_v3(query: &[u8], body_md5: &[u8], ts: i32) -> [u8; 20] {
        let index = ((iv(query, body_md5, ts) & 15) / 3) as usize;
        let iv_v1 = [
            0xc4a7_8580_u32,
            0xb3c0_fd39,
            0xc58c_5686,
            0xc9aa_3ba7,
            0xf5a7_adf2,
            0x963c_2ed1,
        ][index];
        const TABLES: [[usize; 11]; 6] = [
            [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
            [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
            [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
            [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
            [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
            [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
        ];
        hash_f13_core(query, body_md5, ts, iv_v1, &TABLES[index], 0)
    }

    fn vectors() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../../tests/data/signing.json")).expect("vectors")
    }

    /// The strongest check available without the upstream: reproduce every
    /// published v3 hash byte-for-byte. v5 shares this core verbatim, so a pass
    /// here means the rotation network, IV chain and MD5 fold are all correct.
    #[test]
    fn reproduces_reference_hash_vectors() {
        for (i, row) in vectors().iter().enumerate() {
            let ts = row["ts"].as_i64().expect("ts") as i32;
            let url = row["url"].as_str().expect("url");
            let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
            let body = row["body"].as_str().map(|s| s.as_bytes().to_vec());
            let query_sm3 = sm3_hash(query.as_bytes());
            let body_md5 = body.as_deref().map(md5_bytes).unwrap_or([0u8; 16]);

            let hash = hash_f13_v3(&query_sm3, &body_md5, ts);
            assert_eq!(
                hex::encode(hash),
                row["hash"].as_str().expect("hash"),
                "hash mismatch on vector {i}"
            );
        }
    }

    /// `helios` shares its whole rotation core with v3; only the licence string
    /// differs. Vector seeds are deterministic (LCG seeded with 17).
    #[test]
    fn reproduces_reference_helios_vectors() {
        let random: u32 = 17u32.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        for (i, row) in vectors().iter().enumerate() {
            let ts = row["ts"].as_i64().expect("ts") as i32;
            assert_eq!(
                helios_with_license(ts, random, V3_LICENSE),
                row["helios"].as_str().expect("helios"),
                "helios mismatch on vector {i}"
            );
        }
    }

    #[test]
    fn hash_f13_needs_branch_twelve() {
        let who = V5Identity::default();
        let mut seen = 0;
        for offset in 0..64 {
            let query = playback_query(&who, 1_780_000_000_000 + offset);
            if branch_v5(&query, None, 1_780_000_000) == 0 {
                seen += 1;
            }
        }
        assert!(seen > 0, "some ticket must land on branch 12");
    }

    #[test]
    fn signed_request_carries_only_the_three_v5_headers_before_ua() {
        let who = V5Identity {
            device_id: "3665151966078755",
            iid: "3665151966082851",
            cdid: "cdid-0",
            ..Default::default()
        };
        let request = sign_playback_v5(
            "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1",
            &who,
            Some(b"{}"),
            1_780_000_000_000,
        )
        .expect("a ticket must land on branch 12");

        let names: Vec<&str> = request.headers.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(names[0], "x-khronos");
        assert_eq!(names[1], "x-helios");
        assert_eq!(names[2], "x-medusa");
        assert_eq!(names[3], "User-Agent");
        assert!(names.contains(&"x-ss-stub"));
        assert!(!names.contains(&"x-argus"));
        assert!(!names.contains(&"x-ladon"));
        assert!(request.url.contains("device_id=3665151966078755"));
    }

    #[test]
    fn helios_is_stable_for_a_fixed_seed() {
        // Same inputs must produce the same header; the random is an argument.
        assert_eq!(
            helios_v5(1_780_000_000, 12345),
            helios_v5(1_780_000_000, 12345)
        );
        assert_ne!(
            helios_v5(1_780_000_000, 12345),
            helios_v5(1_780_000_001, 12345)
        );
    }

    #[test]
    fn medusa_is_not_empty_and_decodes() {
        let who = V5Identity {
            device_id: "3665151966078755",
            iid: "3665151966082851",
            cdid: "cdid-0",
            ..Default::default()
        };
        // medusa embeds the F13 hash, which requires branch 12 — that is why it
        // is only reachable through the signer, never called directly.
        let request = sign_playback_v5(
            "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1",
            &who,
            Some(b"{}"),
            1_780_000_000_000,
        )
        .expect("a ticket must land on branch 12");

        let medusa = request
            .headers
            .iter()
            .find(|(k, _)| k == "x-medusa")
            .map(|(_, v)| v.clone())
            .expect("x-medusa header");
        let decoded = BASE64.decode(&medusa).expect("medusa is base64");
        assert!(
            decoded.len() > 248,
            "medusa payload too short: {}",
            decoded.len()
        );
    }
}

/// v3 medusa reimplementation, kept strictly for vector validation.
#[cfg(test)]
pub(super) mod v3_reference {
    use super::*;

    /// The deterministic LCG the reference test harness injects.
    pub struct Lcg(pub u32);

    impl Lcg {
        pub fn new(seed: u32) -> Self {
            Lcg(seed)
        }
        pub fn next_u32(&mut self) -> u32 {
            self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            self.0
        }
        pub fn next_double(&mut self) -> f64 {
            self.next_u32() as f64 / 4_294_967_296.0
        }
    }

    fn v3_sbox() -> Vec<u8> {
        BASE64
            .decode(include_str!("../../tests/data/v3_sbox.b64").trim())
            .expect("v3 sbox base64")
    }

    fn device_proto(device_id: &str) -> Vec<u8> {
        proto(&[
            (1, Field::Sint(1)),
            (2, Field::Sint(2)),
            s(3, "8662"),
            s(4, device_id),
            s(5, "Ai6svO3PyrwDOUSmO6ZcResxu"),
            s(6, "!noperm!"),
            (7, Field::Sint(-888_888)),
            (8, Field::Sint(-888_888)),
            (9, Field::Sint(3)),
            (10, Field::Sint(-888_888)),
            s(11, "!notset!"),
            s(12, "Asia/Shanghai,8"),
            s(13, "zh_CN"),
            (14, Field::Sint(4)),
            (16, Field::Float(255.249_94)),
            (17, Field::Float(35.585_99)),
            (18, Field::Float(3.467_449_2)),
            (19, Field::Float(3.467_449_2)),
            (20, Field::Float(255.175_49)),
            (21, Field::Float(42.175_44)),
            s(22, "16"),
            (23, Field::Sint(41)),
            (24, Field::Sint(36)),
            (25, Field::Sint(1_728_388_016_635)),
            (26, Field::Sint(1_728_388_016_635)),
            (27, Field::Sint(1_728_388_016_635)),
            (28, Field::Sint(1_728_388_016_637)),
            (29, Field::Sint(-1)),
            s(30, "25053RT47C"),
            s(31, "Redmi"),
            s(32, "25053RT47C"),
            s(33, "25053RT47C"),
            s(34, "Xiaomi"),
            s(35, "Redmi"),
            s(36, "Redmi"),
            (38, Field::Sint(31)),
        ])
    }

    pub fn medusa_v3(
        url: &str,
        body: Option<&[u8]>,
        ts: i32,
        device_id: &str,
        version: &str,
        rng: &mut Lcg,
    ) -> String {
        let body_md5 = body.map(md5_bytes).unwrap_or([0u8; 16]);
        let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
        let query_sm3 = sm3_hash(query.as_bytes());
        let query_body_ts = super::tests::hash_f13_v3(&query_sm3, &body_md5, ts);

        let nested = proto(&[
            (1, Field::Sint(111)),
            (2, Field::Sint(10)),
            (3, Field::Sint(694_367)),
            (5, Field::Sint(586_952_199)),
        ]);

        let message_rand = rng.next_u32() as i64;
        let env_launch = (rng.next_double() * 21.0) as i64 + 100;
        let env_pid = (rng.next_double() * 2000.0) as i64 + 10_001;

        let env = proto(&[
            (1, Field::Sint(env_launch)),
            (2, Field::Sint(146_331_399)),
            (3, Field::Sint(146_331_396)),
            (5, Field::Sint(7)),
            s(6, "v04.06.04.03-bugfix"),
            (7, Field::Sint(env_pid)),
            (12, Field::Bytes(device_proto(device_id))),
            (
                13,
                Field::Bytes(proto(&[
                    (1, Field::Sint(ts as i64)),
                    (2, Field::Sint(-2)),
                    (4, Field::Sint(200)),
                ])),
            ),
            s(14, version),
        ]);

        let mut query_hash_input = Vec::new();
        query_hash_input.extend_from_slice(query.as_bytes());
        query_hash_input.extend_from_slice(&body_md5);
        query_hash_input.extend_from_slice(b"none");
        let query_hash = sm3_hash(&query_hash_input);

        let message = proto(&[
            (
                1,
                Field::Bytes(parse_hex("f7e85ffad7d7dc3bd62ac87057cf6118")),
            ),
            (2, Field::Sint(3)),
            (3, Field::Sint(message_rand)),
            s(4, "8662"),
            s(5, device_id),
            s(6, "1588093228"),
            s(7, version),
            s(8, "v04.06.04-ml-android"),
            (9, Field::Sint(67_503_104)),
            (10, Field::Bytes(parse_hex("4001000000000000"))),
            (12, Field::Sint(ts as i64)),
            (13, Field::Bytes(query_body_ts.to_vec())),
            (14, Field::Bytes(query_sm3[..6].to_vec())),
            (15, Field::Bytes(nested)),
            s(16, "AXYQOS6n2m60x1fVZHIrH3iol"),
            (17, Field::Sint(ts as i64)),
            (19, Field::Bytes(query_hash.to_vec())),
            s(20, "none"),
            (21, Field::Sint(312)),
            (23, Field::Bytes(env)),
            s(
                24,
                r#"{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}"#,
            ),
        ]);

        let r = rng.next_u32();
        let sign_key =
            parse_hex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5");
        let mut hash_input = Vec::with_capacity(68);
        hash_input.extend_from_slice(&sign_key);
        hash_input.extend_from_slice(&le32(r));
        hash_input.extend_from_slice(&sign_key);
        let hash = sm3_hash(&hash_input);

        let d1 = (r >> 16) & 255;
        let seed_word = ((d1 << 11) | (r >> 24)) ^ (d1 >> 5) ^ d1;
        let seed = le32(!seed_word);

        let mut transformed: Vec<u8> = parse_hex("4001000000000000");
        transformed.extend_from_slice(&xmxor(&message, &hash));
        transformed.reverse();
        for i in 0..transformed.len() {
            transformed[i] ^= seed[3 - (i & 3)];
        }

        let check = (((query_sm3[0] as u32) & 63) << 14)
            | 0x1800_0001
            | (((query_body_ts[0] as u32) & 63) << 8);

        let mut packed = Vec::new();
        packed.push(0x35);
        packed.extend_from_slice(&le32(rng.next_u32()));
        packed.extend_from_slice(&le32(check));
        packed.extend_from_slice(&transformed);
        packed.push((r >> 16) as u8);
        packed.push((r >> 24) as u8);

        let aes = AesV3::new(
            &parse_hex("f1593376766ea98d34f31b057a9d5be4"),
            ts,
            false,
            &v3_sbox(),
        );
        let encrypted = aes.encrypt(&packed, &parse_hex("1fe109a4125283f418de9e051a969e12"));

        let version_bytes = parse_hex("03000000f7e85ffad7d7dc3bd62ac87057cf6118");
        let mut prefix = Vec::with_capacity(20);
        for i in (0..20).step_by(4) {
            let word = u32::from_le_bytes([
                version_bytes[i],
                version_bytes[i + 1],
                version_bytes[i + 2],
                version_bytes[i + 3],
            ]);
            prefix.extend_from_slice(&le32(word ^ ts as u32));
        }

        let mut out = prefix;
        out.push(r as u8);
        out.push((r >> 8) as u8);
        out.push(0);
        out.push(1);
        out.extend_from_slice(&encrypted);
        BASE64.encode(out)
    }
}

#[cfg(test)]
mod vector_tests {
    use super::v3_reference::{medusa_v3, Lcg};

    #[test]
    fn reproduces_reference_medusa_vectors() {
        let rows: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../../tests/data/signing.json")).expect("vectors");
        for (i, row) in rows.iter().enumerate() {
            let ts = row["ts"].as_i64().expect("ts") as i32;
            let url = row["url"].as_str().expect("url");
            let body = row["body"].as_str().map(|s| s.as_bytes().to_vec());
            let mut rng = Lcg::new(17);
            // helios consumes the first random in the reference harness.
            let _ = rng.next_u32();
            let value = medusa_v3(
                url,
                body.as_deref(),
                ts,
                "1905892595378490",
                "7.1.3.32",
                &mut rng,
            );
            assert_eq!(
                value,
                row["medusa"].as_str().expect("medusa"),
                "medusa mismatch on vector {i}"
            );
        }
    }
}
