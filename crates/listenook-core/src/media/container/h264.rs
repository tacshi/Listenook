//! Just enough H.264 to put an AVI file's pictures in the order they are shown.
//!
//! AVI keeps pictures in the order they are decoded and says nothing of the order they are
//! shown in, which differs once a stream has B-frames. MP4 needs both, so the order is read
//! from each picture's first slice header: its picture order count (POC).

use std::collections::HashMap;

/// Splits an Annex B byte stream (NAL units after `00 00 01` start codes) into its NAL units.
/// `None` when the data does not start with a start code (leading zero bytes aside).
pub(super) fn nal_units(data: &[u8]) -> Option<Vec<&[u8]>> {
    let mut starts = Vec::new();
    let mut at = 0;
    while at + 3 <= data.len() {
        if data[at] == 0 && data[at + 1] == 0 && data[at + 2] == 1 {
            starts.push(at + 3);
            at += 3;
        } else {
            at += 1;
        }
    }
    let first = *starts.first()?;
    if data[..first - 3].iter().any(|byte| *byte != 0) {
        return None;
    }
    let units = starts
        .iter()
        .enumerate()
        .map(|(index, &start)| {
            let end = starts.get(index + 1).map_or(data.len(), |next| next - 3);
            let mut unit = &data[start..end.max(start)];
            while let [rest @ .., 0] = unit {
                unit = rest;
            }
            unit
        })
        .filter(|unit| !unit.is_empty())
        .collect();
    Some(units)
}

pub(super) fn kind(nal: &[u8]) -> u8 {
    nal.first().map_or(0, |header| header & 0x1f)
}

/// The NAL unit's payload without its emulation-prevention bytes, up to `limit` bytes:
/// enough for the headers read here.
fn payload(nal: &[u8], limit: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(limit.min(nal.len()));
    let mut zeros = 0;
    for &byte in nal.iter().skip(1) {
        if out.len() >= limit {
            break;
        }
        if zeros >= 2 && byte == 3 {
            zeros = 0;
            continue;
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
        out.push(byte);
    }
    out
}

struct Bits<'a> {
    data: &'a [u8],
    at: usize,
}

impl Bits<'_> {
    fn bit(&mut self) -> Option<u32> {
        let byte = *self.data.get(self.at / 8)?;
        let bit = (byte >> (7 - self.at % 8)) & 1;
        self.at += 1;
        Some(u32::from(bit))
    }

    fn bits(&mut self, count: u32) -> Option<u32> {
        (0..count).try_fold(0, |value, _| Some((value << 1) | self.bit()?))
    }

    fn flag(&mut self) -> Option<bool> {
        Some(self.bit()? == 1)
    }

    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some(((1_u64 << zeros) - 1 + u64::from(self.bits(zeros)?)) as u32)
    }

    fn se(&mut self) -> Option<i32> {
        let value = i64::from(self.ue()?);
        Some(if value % 2 == 1 { (value + 1) / 2 } else { -(value / 2) } as i32)
    }
}

/// What a sequence parameter set says that is needed here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Sps {
    pub chroma_format: u8,
    pub luma_depth_minus8: u8,
    pub chroma_depth_minus8: u8,
    separate_planes: bool,
    frame_num_bits: u32,
    order_type: u32,
    order_bits: u32,
    frames_only: bool,
}

const HIGH_PROFILES: [u8; 12] = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134];

pub(super) fn sps(nal: &[u8]) -> Option<(u32, Sps)> {
    let data = payload(nal, 256);
    let profile = *data.first()?;
    let mut bits = Bits { data: &data, at: 24 };
    let id = bits.ue()?;
    let mut sps = Sps {
        chroma_format: 1,
        luma_depth_minus8: 0,
        chroma_depth_minus8: 0,
        separate_planes: false,
        frame_num_bits: 0,
        order_type: 0,
        order_bits: 0,
        frames_only: true,
    };
    if HIGH_PROFILES.contains(&profile) || profile == 135 {
        sps.chroma_format = bits.ue()?.min(3) as u8;
        if sps.chroma_format == 3 {
            sps.separate_planes = bits.flag()?;
        }
        sps.luma_depth_minus8 = bits.ue()?.min(7) as u8;
        sps.chroma_depth_minus8 = bits.ue()?.min(7) as u8;
        bits.flag()?;
        if bits.flag()? {
            for list in 0..if sps.chroma_format == 3 { 12 } else { 8 } {
                if bits.flag()? {
                    let (mut last, mut next) = (8_i32, 8_i32);
                    for _ in 0..if list < 6 { 16 } else { 64 } {
                        if next != 0 {
                            next = (last + bits.se()? + 256) % 256;
                        }
                        if next != 0 {
                            last = next;
                        }
                    }
                }
            }
        }
    }
    sps.frame_num_bits = bits.ue()?.checked_add(4).filter(|bits| *bits <= 16)?;
    sps.order_type = bits.ue()?;
    match sps.order_type {
        0 => sps.order_bits = bits.ue()?.checked_add(4).filter(|bits| *bits <= 16)?,
        1 => {
            bits.flag()?;
            bits.se()?;
            bits.se()?;
            for _ in 0..bits.ue()?.min(255) {
                bits.se()?;
            }
        }
        2 => {}
        _ => return None,
    }
    bits.ue()?;
    bits.flag()?;
    bits.ue()?;
    bits.ue()?;
    sps.frames_only = bits.flag()?;
    Some((id, sps))
}

/// A picture parameter set's id, its sequence parameter set's id, and whether its slices say
/// how far the bottom field's order count is from the top's.
fn pps(nal: &[u8]) -> Option<(u32, (u32, bool))> {
    let data = payload(nal, 16);
    let mut bits = Bits { data: &data, at: 0 };
    let id = bits.ue()?;
    let sps = bits.ue()?;
    bits.flag()?;
    Some((id, (sps, bits.flag()?)))
}

/// Follows a stream's parameter sets and works out each picture's place in the order shown.
#[derive(Default)]
pub(super) struct Order {
    sps: HashMap<u32, Sps>,
    pps: HashMap<u32, (u32, bool)>,
    period: u32,
    previous_msb: i32,
    previous_lsb: i32,
}

impl Order {
    /// Takes in a sequence or picture parameter set; other NAL units are passed over.
    pub(super) fn parameters(&mut self, nal: &[u8]) {
        match kind(nal) {
            7 => {
                if let Some((id, sps)) = sps(nal) {
                    self.sps.insert(id, sps);
                }
            }
            8 => {
                if let Some((id, pps)) = pps(nal) {
                    self.pps.insert(id, pps);
                }
            }
            _ => {}
        }
    }

    /// Where a picture is shown, from its first slice: pictures sort by `(period, count)`,
    /// a period starting at each IDR picture. Streams whose order count is worked out from
    /// frame numbers (type 1) are refused; type 2 cannot reorder, so its count stays 0 and
    /// the decoding order stands.
    pub(super) fn picture(&mut self, slice: &[u8]) -> Result<(u32, i32), &'static str> {
        let idr = kind(slice) == 5;
        let referenced = slice.first().is_some_and(|header| header & 0x60 != 0);
        let data = payload(slice, 64);
        let mut bits = Bits { data: &data, at: 0 };
        let unreadable = "an unreadable H.264 slice header";
        bits.ue().ok_or(unreadable)?;
        bits.ue().ok_or(unreadable)?;
        let (sps_id, _) = *self.pps.get(&bits.ue().ok_or(unreadable)?).ok_or("a slice before its parameters")?;
        let sps = *self.sps.get(&sps_id).ok_or("a slice before its parameters")?;
        if idr {
            self.period += 1;
            (self.previous_msb, self.previous_lsb) = (0, 0);
        }
        match sps.order_type {
            0 => {}
            2 => return Ok((self.period, 0)),
            _ => return Err("H.264 picture order type 1"),
        }
        if sps.separate_planes {
            bits.bits(2).ok_or(unreadable)?;
        }
        bits.bits(sps.frame_num_bits).ok_or(unreadable)?;
        if !sps.frames_only && bits.flag().ok_or(unreadable)? {
            bits.flag().ok_or(unreadable)?;
        }
        if idr {
            bits.ue().ok_or(unreadable)?;
        }
        let lsb = bits.bits(sps.order_bits).ok_or(unreadable)? as i32;
        let most = 1 << sps.order_bits;
        let msb = if lsb < self.previous_lsb && self.previous_lsb - lsb >= most / 2 {
            self.previous_msb + most
        } else if lsb > self.previous_lsb && lsb - self.previous_lsb > most / 2 {
            self.previous_msb - most
        } else {
            self.previous_msb
        };
        if referenced {
            (self.previous_msb, self.previous_lsb) = (msb, lsb);
        }
        Ok((self.period, msb + lsb))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annex_b_splits_on_both_start_code_lengths() {
        let data = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 0];
        let units = nal_units(&data).unwrap();
        assert_eq!(units, vec![&[0x67, 1, 2][..], &[0x68, 3], &[0x65, 4]]);
        assert!(nal_units(&[0, 0, 0, 5, 0x65, 1]).is_none(), "lengths, not start codes");
    }

    #[test]
    fn exp_golomb_codes_are_read() {
        // 1 | 010 | 011 | 00100 | 00101 → ue 0, 1, 2, 3, 4; then 011 as se is -1.
        let data = [0b1010_0110, 0b0100_0010, 0b1011_0000];
        let mut bits = Bits { data: &data, at: 0 };
        let read: Vec<u32> = (0..5).map(|_| bits.ue().unwrap()).collect();
        assert_eq!(read, [0, 1, 2, 3, 4]);
        assert_eq!(bits.se(), Some(-1));
    }

    #[test]
    fn emulation_prevention_bytes_are_dropped() {
        assert_eq!(payload(&[0x67, 0, 0, 3, 1, 0, 0, 3], 16), vec![0, 0, 1, 0, 0]);
    }
}
