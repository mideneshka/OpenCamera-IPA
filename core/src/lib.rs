// SPDX-License-Identifier: GPL-3.0-or-later
//! Portable CPU reference backend. Input/output: straight-alpha RGBA8 sRGB.
//! No platform APIs, network, file I/O or third-party dependencies.
pub mod ffi;

#[derive(Debug, PartialEq)]
pub enum Error {
    Dimensions,
    Parameters,
    Memory,
    Cancelled,
    NoFrames,
}
pub type Result<T> = std::result::Result<T, Error>;
pub const MAX_PIXELS: usize = 13_000_000;

#[derive(Clone, Debug)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}
impl Image {
    pub fn new(width: usize, height: usize, pixels: Vec<u8>) -> Result<Self> {
        let len = image_len(width, height)?;
        if pixels.len() != len {
            return Err(Error::Dimensions);
        }
        Ok(Self {
            width,
            height,
            pixels,
        })
    }
    fn gray(&self, x: usize, y: usize) -> f32 {
        let p = (y * self.width + x) * 4;
        (self.pixels[p] as f32 * 0.2126
            + self.pixels[p + 1] as f32 * 0.7152
            + self.pixels[p + 2] as f32 * 0.0722)
            / 255.0
    }
}
pub fn image_len(w: usize, h: usize) -> Result<usize> {
    let n = w.checked_mul(h).ok_or(Error::Dimensions)?;
    if w == 0 || h == 0 || n > MAX_PIXELS {
        return Err(Error::Dimensions);
    }
    n.checked_mul(4).ok_or(Error::Dimensions)
}
fn buffer(len: usize) -> Result<Vec<u8>> {
    let mut v = Vec::new();
    v.try_reserve_exact(len).map_err(|_| Error::Memory)?;
    v.resize(len, 0);
    Ok(v)
}
fn cancelled(stop: &impl Fn() -> bool) -> Result<()> {
    if stop() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}
fn byte(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u8
}
fn linear(v: f32) -> f32 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}
fn srgb(v: f32) -> f32 {
    if v <= 0.0031308 {
        12.92 * v
    } else {
        1.055 * v.max(0.0).powf(1.0 / 2.4) - 0.055
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Alignment {
    /// Sample the candidate at reference position + (dx, dy).
    pub dx: i32,
    pub dy: i32,
    pub correlation: f32,
    pub accepted: u32,
}
fn correlation(a: &Image, b: &Image, dx: i32, dy: i32) -> Option<f32> {
    let step = (a.width.max(a.height) / 96).max(1);
    let mut n = 0.0f64;
    let mut sa = 0.0f64;
    let mut sb = 0.0f64;
    let mut aa = 0.0f64;
    let mut bb = 0.0f64;
    let mut ab = 0.0f64;
    for y in (0..a.height).step_by(step) {
        for x in (0..a.width).step_by(step) {
            let bx = x as i32 + dx;
            let by = y as i32 + dy;
            if bx < 0 || by < 0 || bx >= b.width as i32 || by >= b.height as i32 {
                continue;
            }
            let u = a.gray(x, y) as f64;
            let v = b.gray(bx as usize, by as usize) as f64;
            n += 1.0;
            sa += u;
            sb += v;
            aa += u * u;
            bb += v * v;
            ab += u * v;
        }
    }
    if n < 64.0 {
        return None;
    }
    let va = aa - sa * sa / n;
    let vb = bb - sb * sb / n;
    if va / n < 0.00001 || vb / n < 0.00001 {
        return None;
    }
    Some(((ab - sa * sb / n) / (va * vb).sqrt()) as f32)
}
pub fn align(a: &Image, b: &Image, radius: i32, stop: &impl Fn() -> bool) -> Result<Alignment> {
    if a.width != b.width || a.height != b.height {
        return Err(Error::Dimensions);
    }
    if !(0..=32).contains(&radius) {
        return Err(Error::Parameters);
    }
    let mut best = Alignment {
        correlation: -1.0,
        ..Alignment::default()
    };
    // Exhaustive bounded translation search. No crop/zoom; unsupported motion is rejected.
    for dy in -radius..=radius {
        cancelled(stop)?;
        for dx in -radius..=radius {
            if let Some(c) = correlation(a, b, dx, dy) {
                if c > best.correlation + 0.000001
                    || ((c - best.correlation).abs() <= 0.000001
                        && dx * dx + dy * dy < best.dx * best.dx + best.dy * best.dy)
                {
                    best = Alignment {
                        dx,
                        dy,
                        correlation: c,
                        accepted: 0,
                    };
                }
            }
        }
    }
    best.accepted = u32::from(best.correlation >= 0.80);
    Ok(best)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FusionMode {
    NoiseReduction,
    ExposureFusion,
}
pub struct FusionResult {
    pub image: Image,
    pub alignments: Vec<Alignment>,
}
pub fn fuse(
    frames: &[Image],
    mode: FusionMode,
    radius: i32,
    stop: &impl Fn() -> bool,
) -> Result<FusionResult> {
    fuse_impl(frames, mode, radius, None, stop)
}
/// Relative shutter*time ISO from capture metadata, referenced to the first frame.
/// JPEG response is approximated by sRGB; this is not a calibrated RAW HDR pipeline.
pub fn fuse_exposed(
    frames: &[Image],
    exposures: &[f32],
    radius: i32,
    stop: &impl Fn() -> bool,
) -> Result<FusionResult> {
    if exposures.len() != frames.len() || exposures.iter().any(|v| !v.is_finite() || *v <= 0.0) {
        return Err(Error::Parameters);
    }
    fuse_impl(
        frames,
        FusionMode::ExposureFusion,
        radius,
        Some(exposures),
        stop,
    )
}
fn fuse_impl(
    frames: &[Image],
    mode: FusionMode,
    radius: i32,
    exposures: Option<&[f32]>,
    stop: &impl Fn() -> bool,
) -> Result<FusionResult> {
    let base = frames.first().ok_or(Error::NoFrames)?;
    if frames.len() > 7 {
        return Err(Error::Parameters);
    }
    let mut shifts = vec![Alignment {
        dx: 0,
        dy: 0,
        correlation: 1.0,
        accepted: 1,
    }];
    for image in &frames[1..] {
        shifts.push(align(base, image, radius, stop)?);
    }
    let linear_table: [f32; 256] = std::array::from_fn(|i| linear(i as f32 / 255.0));
    let mut out = buffer(base.pixels.len())?;
    for y in 0..base.height {
        cancelled(stop)?;
        for x in 0..base.width {
            let p = (y * base.width + x) * 4;
            let reference = base.gray(x, y);
            let mut rgb = [0.0; 3];
            let mut total = 0.0;
            for (i, (frame, s)) in frames.iter().zip(&shifts).enumerate() {
                if s.accepted == 0 {
                    continue;
                }
                let sx = x as i32 + s.dx;
                let sy = y as i32 + s.dy;
                if sx < 0 || sy < 0 || sx >= base.width as i32 || sy >= base.height as i32 {
                    continue;
                }
                let q = (sy as usize * base.width + sx as usize) * 4;
                let value = frame.gray(sx as usize, sy as usize);
                // NR deghosting: keep reference for strong local disagreements.
                if mode == FusionMode::NoiseReduction && i > 0 && (value - reference).abs() > 0.10 {
                    continue;
                }
                // Ignore sensor-floor and clipped samples when an exposure model is available.
                let weight = if exposures.is_some() {
                    let peak = frame.pixels[q..q + 3].iter().copied().max().unwrap() as f32 / 255.0;
                    if value < 0.015 || peak > 0.98 {
                        continue;
                    }
                    (value.min(1.0 - peak)).max(0.001)
                } else if mode == FusionMode::ExposureFusion {
                    (-((value - 0.5) / 0.24).powi(2)).exp().max(0.001)
                } else {
                    1.0
                };
                for (c, channel) in rgb.iter_mut().enumerate() {
                    let scale = exposures.map(|e| e[0] / e[i]).unwrap_or(1.0);
                    *channel += linear_table[frame.pixels[q + c] as usize] * weight * scale;
                }
                total += weight;
            }
            if total == 0.0 {
                out[p..p + 4].copy_from_slice(&base.pixels[p..p + 4]);
                continue;
            }
            for v in &mut rgb {
                *v /= total;
            }
            if exposures.is_some() {
                // One shared monotonic tone curve preserves colour ratios and highlight order.
                let peak = rgb.iter().copied().fold(0.0, f32::max);
                let gain = 1.0 / (0.35 + peak);
                for v in &mut rgb {
                    *v *= gain;
                }
            }
            for c in 0..3 {
                out[p + c] = byte(srgb(rgb[c]));
            }
            out[p + 3] = base.pixels[p + 3];
        }
    }
    Ok(FusionResult {
        image: Image::new(base.width, base.height, out)?,
        alignments: shifts,
    })
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Adjustments {
    pub denoise: f32,
    pub dehaze: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub temperature: f32,
    pub sharpen: f32,
}
impl Default for Adjustments {
    fn default() -> Self {
        Self {
            denoise: 0.0,
            dehaze: 0.0,
            contrast: 0.0,
            saturation: 1.0,
            temperature: 0.0,
            sharpen: 0.0,
        }
    }
}
impl Adjustments {
    pub fn validate(&self) -> Result<()> {
        for (v, lo, hi) in [
            (self.denoise, 0.0, 16.0),
            (self.dehaze, 0.0, 1.0),
            (self.contrast, 0.0, 1.0),
            (self.saturation, 0.0, 2.0),
            (self.temperature, -1.0, 1.0),
            (self.sharpen, 0.0, 1.0),
        ] {
            if !v.is_finite() || v < lo || v > hi {
                return Err(Error::Parameters);
            }
        }
        Ok(())
    }
}
fn clamped(v: isize, n: usize) -> usize {
    v.clamp(0, n as isize - 1) as usize
}
fn ycc(image: &Image, x: usize, y: usize) -> [f32; 3] {
    let p = (y * image.width + x) * 4;
    let r = image.pixels[p] as f32;
    let g = image.pixels[p + 1] as f32;
    let b = image.pixels[p + 2] as f32;
    [
        0.299 * r + 0.587 * g + 0.114 * b,
        -0.168736 * r - 0.331264 * g + 0.5 * b,
        0.5 * r - 0.418688 * g - 0.081312 * b,
    ]
}
/// Exact 3x3-patch / 7x7-search NLM with cached colour rows and sliding patch sums.
/// Only nine YCbCr rows and one accumulation row are retained (no full-image float cache).
pub fn nlm(image: &Image, strength: f32, stop: &impl Fn() -> bool) -> Result<Image> {
    if !strength.is_finite() || !(0.0..=16.0).contains(&strength) {
        return Err(Error::Parameters);
    }
    if strength == 0.0 {
        return Ok(image.clone());
    }
    let w = image.width;
    let h = image.height;
    let mut output = buffer(image.pixels.len())?;
    let mut rows = Vec::new();
    rows.try_reserve_exact(9 * w).map_err(|_| Error::Memory)?;
    rows.resize(9 * w, [0.0f32; 3]);
    let mut row_ids = [usize::MAX; 9];
    let mut sums = Vec::new();
    sums.try_reserve_exact(w).map_err(|_| Error::Memory)?;
    sums.resize(w, [0.0f32; 4]);
    let mut columns = Vec::new();
    columns
        .try_reserve_exact(w + 2)
        .map_err(|_| Error::Memory)?;
    columns.resize(w + 2, 0.0f32);
    let divisor = 18.0 * strength * strength;
    let distance = |a: [f32; 3], b: [f32; 3]| {
        (a[0] - b[0]).powi(2) + 0.5 * (a[1] - b[1]).powi(2) + 0.5 * (a[2] - b[2]).powi(2)
    };
    for y in 0..h {
        cancelled(stop)?;
        for yy in y.saturating_sub(4)..=(y + 4).min(h - 1) {
            let slot = yy % 9;
            if row_ids[slot] != yy {
                for x in 0..w {
                    rows[slot * w + x] = ycc(image, x, yy);
                }
                row_ids[slot] = yy;
            }
        }
        sums.fill([0.0; 4]);
        for dy in -3isize..=3 {
            let cy = clamped(y as isize + dy, h);
            for dx in -3isize..=3 {
                for (column, value) in columns.iter_mut().enumerate() {
                    let xx = column as isize - 1;
                    *value = 0.0;
                    for py in -1isize..=1 {
                        let ay = clamped(y as isize + py, h) % 9;
                        let by = clamped(cy as isize + py, h) % 9;
                        *value += distance(
                            rows[ay * w + clamped(xx, w)],
                            rows[by * w + clamped(xx + dx, w)],
                        );
                    }
                }
                for (x, sum) in sums.iter_mut().enumerate() {
                    let cx = clamped(x as isize + dx, w);
                    let d = if (0..w as isize).contains(&(x as isize + dx)) {
                        columns[x] + columns[x + 1] + columns[x + 2]
                    } else {
                        // Clamp the neighbour centre before its patch, as in the reference.
                        let mut d = 0.0;
                        for py in -1isize..=1 {
                            let ay = clamped(y as isize + py, h) % 9;
                            let by = clamped(cy as isize + py, h) % 9;
                            for px in -1isize..=1 {
                                d += distance(
                                    rows[ay * w + clamped(x as isize + px, w)],
                                    rows[by * w + clamped(cx as isize + px, w)],
                                );
                            }
                        }
                        d
                    };
                    let weight = (-d / divisor).exp();
                    let q = (cy * w + cx) * 4;
                    for (c, channel) in sum.iter_mut().enumerate().take(3) {
                        *channel += image.pixels[q + c] as f32 * weight;
                    }
                    sum[3] += weight;
                }
            }
        }
        for (x, sum) in sums.iter().enumerate() {
            let p = (y * w + x) * 4;
            for c in 0..3 {
                output[p + c] = (sum[c] / sum[3]).round() as u8;
            }
            output[p + 3] = image.pixels[p + 3];
        }
    }
    Image::new(w, h, output)
}
pub fn process(image: &Image, settings: Adjustments, stop: &impl Fn() -> bool) -> Result<Image> {
    settings.validate()?;
    let source = nlm(image, settings.denoise, stop)?;
    if settings.dehaze == 0.0
        && settings.contrast == 0.0
        && settings.saturation == 1.0
        && settings.temperature == 0.0
    {
        cancelled(stop)?;
        return if settings.sharpen == 0.0 {
            Ok(source)
        } else {
            sharpen(&source, settings.sharpen, stop)
        };
    }
    let linear_table: [f32; 256] = std::array::from_fn(|i| linear(i as f32 / 255.0));
    let mut output = buffer(source.pixels.len())?;
    for y in 0..image.height {
        cancelled(stop)?;
        for x in 0..image.width {
            let p = (y * image.width + x) * 4;
            let mut color = [0.0; 3];
            let mut dark = 1.0f32;
            if settings.dehaze > 0.0 {
                for dy in [-8isize, 0, 8] {
                    for dx in [-8isize, 0, 8] {
                        let q = (clamped(y as isize + dy, image.height) * image.width
                            + clamped(x as isize + dx, image.width))
                            * 4;
                        for c in 0..3 {
                            dark = dark.min(linear_table[source.pixels[q + c] as usize]);
                        }
                    }
                }
            }
            let haze = (dark * settings.dehaze).min(0.08 * settings.dehaze);
            for (c, channel) in color.iter_mut().enumerate() {
                *channel =
                    ((linear_table[source.pixels[p + c] as usize] - haze) / (1.0 - haze)).max(0.0);
            }
            color[0] *= 1.0 + settings.temperature * 0.2;
            color[2] *= 1.0 - settings.temperature * 0.2;
            let luma = color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
            let target = luma + settings.contrast * (luma * luma * (3.0 - 2.0 * luma) - luma);
            let ratio = if luma > 0.00001 { target / luma } else { 1.0 };
            for c in 0..3 {
                let v = target + (color[c] * ratio - target) * settings.saturation;
                output[p + c] = byte(srgb(v));
            }
            output[p + 3] = source.pixels[p + 3];
        }
    }
    let image = Image::new(image.width, image.height, output)?;
    if settings.sharpen == 0.0 {
        return Ok(image);
    }
    sharpen(&image, settings.sharpen, stop)
}
/// Bounded unsharp mask, deliberately NOT branded as AMD RCAS.
fn sharpen(image: &Image, amount: f32, stop: &impl Fn() -> bool) -> Result<Image> {
    let mut out = image.clone();
    for y in 0..image.height {
        cancelled(stop)?;
        for x in 0..image.width {
            let p = (y * image.width + x) * 4;
            for c in 0..3 {
                let mut blur = 0.0;
                for (dx, dy) in [(0isize, -1isize), (-1, 0), (1, 0), (0, 1)] {
                    let q = (clamped(y as isize + dy, image.height) * image.width
                        + clamped(x as isize + dx, image.width))
                        * 4;
                    blur += image.pixels[q + c] as f32 / 4.0;
                }
                let value = image.pixels[p + c] as f32;
                out.pixels[p + c] = (value + (value - blur).clamp(-24.0, 24.0) * amount)
                    .clamp(0.0, 255.0)
                    .round() as u8;
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn texture(w: usize, h: usize) -> Image {
        let mut bytes = vec![0; w * h * 4];
        let mut state = 7u32;
        for p in bytes.chunks_mut(4) {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let v = 50 + (state >> 24) as u8 % 150;
            p.copy_from_slice(&[v, v, v, 255]);
        }
        Image::new(w, h, bytes).unwrap()
    }
    #[test]
    fn rejects_bad_dimensions_and_nan() {
        assert_eq!(image_len(usize::MAX, 2), Err(Error::Dimensions));
        assert!(Image::new(3, 2, vec![0; 20]).is_err());
        assert_eq!(
            Adjustments {
                saturation: f32::NAN,
                ..Default::default()
            }
            .validate(),
            Err(Error::Parameters)
        );
    }
    #[test]
    fn identity_preserves_alpha_and_pixels() {
        let mut im = texture(20, 16);
        im.pixels[3] = 123;
        assert_eq!(
            process(&im, Adjustments::default(), &|| false)
                .unwrap()
                .pixels,
            im.pixels
        );
    }
    #[test]
    fn translation_direction_and_no_crop() {
        let a = texture(48, 40);
        let mut b = a.clone();
        for y in 0..37 {
            for x in 0..46 {
                let p = (y * 48 + x) * 4;
                let q = ((y + 3) * 48 + x + 2) * 4;
                b.pixels[q..q + 4].copy_from_slice(&a.pixels[p..p + 4]);
            }
        }
        let s = align(&a, &b, 5, &|| false).unwrap();
        assert_eq!((s.dx, s.dy, s.accepted), (2, 3, 1));
        let f = fuse(&[a.clone(), b], FusionMode::NoiseReduction, 5, &|| false).unwrap();
        assert_eq!(f.image.pixels, a.pixels);
    }
    #[test]
    fn textureless_is_rejected() {
        let a = Image::new(16, 16, vec![120; 16 * 16 * 4]).unwrap();
        assert_eq!(align(&a, &a, 2, &|| false).unwrap().accepted, 0);
    }
    #[test]
    fn unrelated_frame_is_rejected() {
        let a = texture(48, 40);
        let mut b = a.clone();
        b.pixels.reverse();
        assert_eq!(align(&a, &b, 3, &|| false).unwrap().accepted, 0);
    }
    #[test]
    fn cancellation_is_reported() {
        let a = texture(12, 12);
        assert!(matches!(
            process(&a, Default::default(), &|| true),
            Err(Error::Cancelled)
        ));
        assert!(matches!(
            fuse(&[a.clone(), a], FusionMode::NoiseReduction, 2, &|| true),
            Err(Error::Cancelled)
        ));
    }
    #[test]
    fn nlm_reduces_flat_noise_without_changing_alpha() {
        let mut a = texture(20, 20);
        let mut before = 0.0;
        for (i, p) in a.pixels.chunks_mut(4).enumerate() {
            let v = (120 + (i * 17 % 11) as i32 - 5) as u8;
            p.copy_from_slice(&[v, v, v, 200]);
            before += (v as f32 - 120.0).powi(2);
        }
        let b = nlm(&a, 7.0, &|| false).unwrap();
        let after: f32 = b
            .pixels
            .chunks(4)
            .map(|p| (p[0] as f32 - 120.0).powi(2))
            .sum();
        assert!(after < before * 0.6);
        assert!(b.pixels.chunks(4).all(|p| p[3] == 200));
    }
    #[test]
    fn warm_moves_red_and_blue_in_opposite_directions() {
        let a = Image::new(8, 8, [120, 120, 120, 255].repeat(64)).unwrap();
        let b = process(
            &a,
            Adjustments {
                temperature: 0.8,
                ..Default::default()
            },
            &|| false,
        )
        .unwrap();
        assert!(b.pixels[0] > a.pixels[0] && b.pixels[2] < a.pixels[2]);
    }
    #[test]
    fn fusion_dimensions_and_counts_checked() {
        assert!(matches!(
            fuse(&[], FusionMode::NoiseReduction, 1, &|| false),
            Err(Error::NoFrames)
        ));
        let a = texture(10, 10);
        let b = texture(11, 10);
        assert!(matches!(
            fuse(&[a, b], FusionMode::NoiseReduction, 1, &|| false),
            Err(Error::Dimensions)
        ));
    }
}

#[cfg(test)]
mod hdr_tests {
    use super::*;
    #[test]
    fn hdr_recovers_shadow_and_clipped_highlight_order() {
        for count in [3, 5, 7] {
            let ev_range = if count == 3 {
                2.0
            } else if count == 5 {
                3.0
            } else {
                4.0
            };
            let mut exposures = vec![1.0];
            for i in 1..count {
                let slot = ((i + 1) / 2) as f32 * if i % 2 == 1 { -1.0 } else { 1.0 };
                exposures.push(2.0f32.powf(slot * ev_range / (count / 2) as f32));
            }
            let frames: Vec<Image> = exposures
                .iter()
                .map(|e| {
                    let mut pixels = vec![255; 128 * 64 * 4];
                    for y in 0..64 {
                        for x in 0..128 {
                            let scene = [0.004, 0.02, 1.3, 2.4][x / 32];
                            let v = byte(srgb(scene * e));
                            let p = (y * 128 + x) * 4;
                            pixels[p..p + 3].fill(v);
                        }
                    }
                    Image::new(128, 64, pixels).unwrap()
                })
                .collect();
            let result = fuse_exposed(&frames, &exposures, 0, &|| false).unwrap();
            let v: Vec<u8> = (0..4)
                .map(|i| result.image.pixels[(32 * 128 + i * 32 + 16) * 4])
                .collect();
            assert!(v[1] > v[0] + 2, "shadow count={count}: {v:?}");
            assert!(
                v[3] > v[2] + 2 && v[3] < 255,
                "highlight count={count}: {v:?}"
            );
            assert_eq!(result.image.width, 128);
        }
    }
    #[test]
    fn hdr_requires_valid_exposure_metadata() {
        let im = Image::new(8, 8, vec![128; 256]).unwrap();
        for exposures in [vec![], vec![0.0], vec![f32::NAN], vec![-1.0]] {
            assert!(matches!(
                fuse_exposed(std::slice::from_ref(&im), &exposures, 0, &|| false),
                Err(Error::Parameters)
            ));
        }
    }
}

#[cfg(test)]
fn nlm_reference(image: &Image, strength: f32, stop: &impl Fn() -> bool) -> Result<Image> {
    if !strength.is_finite() || !(0.0..=16.0).contains(&strength) {
        return Err(Error::Parameters);
    }
    if strength == 0.0 {
        return Ok(image.clone());
    }
    let mut output = buffer(image.pixels.len())?;
    let h2 = strength * strength;
    for y in 0..image.height {
        cancelled(stop)?;
        for x in 0..image.width {
            let mut sum = [0.0; 3];
            let mut weights = 0.0;
            for dy in -3isize..=3 {
                for dx in -3isize..=3 {
                    let cx = clamped(x as isize + dx, image.width);
                    let cy = clamped(y as isize + dy, image.height);
                    let mut distance = 0.0;
                    for py in -1isize..=1 {
                        for px in -1isize..=1 {
                            let a = ycc(
                                image,
                                clamped(x as isize + px, image.width),
                                clamped(y as isize + py, image.height),
                            );
                            let b = ycc(
                                image,
                                clamped(cx as isize + px, image.width),
                                clamped(cy as isize + py, image.height),
                            );
                            distance += (a[0] - b[0]).powi(2)
                                + 0.5 * (a[1] - b[1]).powi(2)
                                + 0.5 * (a[2] - b[2]).powi(2);
                        }
                    }
                    let w = (-distance / (18.0 * h2)).exp();
                    let q = (cy * image.width + cx) * 4;
                    for (c, channel) in sum.iter_mut().enumerate() {
                        *channel += image.pixels[q + c] as f32 * w;
                    }
                    weights += w;
                }
            }
            let p = (y * image.width + x) * 4;
            for c in 0..3 {
                output[p + c] = (sum[c] / weights).round() as u8;
            }
            output[p + 3] = image.pixels[p + 3];
        }
    }
    Image::new(image.width, image.height, output)
}

#[cfg(test)]
#[test]
fn optimized_nlm_matches_reference_including_edges() {
    for (w, h) in [(1, 1), (2, 5), (13, 11), (37, 19)] {
        let pixels = (0..w * h * 4)
            .map(|i| ((i * 73 + i * i * 19) % 256) as u8)
            .collect();
        let image = Image::new(w, h, pixels).unwrap();
        for strength in [0.1, 3.0, 7.0, 16.0] {
            let a = nlm_reference(&image, strength, &|| false).unwrap();
            let b = nlm(&image, strength, &|| false).unwrap();
            for (i, (a, b)) in a.pixels.iter().zip(&b.pixels).enumerate() {
                assert!(
                    (*a as i16 - *b as i16).abs() <= 1,
                    "{w}x{h}, pixel {i}: {a} != {b}"
                );
                if i % 4 == 3 {
                    assert_eq!(a, b);
                }
            }
        }
    }
}
#[cfg(test)]
#[test]
#[ignore = "manual release benchmark"]
fn benchmark_nlm_reference_and_optimized() {
    let (w, h) = (512, 384);
    let image = Image::new(
        w,
        h,
        (0..w * h * 4)
            .map(|i| ((i * 73 + i * i * 19) % 256) as u8)
            .collect(),
    )
    .unwrap();
    let started = std::time::Instant::now();
    let a = nlm_reference(&image, 7.0, &|| false).unwrap();
    let reference = started.elapsed();
    let started = std::time::Instant::now();
    let b = nlm(&image, 7.0, &|| false).unwrap();
    let optimized = started.elapsed();
    assert!(a
        .pixels
        .iter()
        .zip(&b.pixels)
        .all(|(a, b)| (*a as i16 - *b as i16).abs() <= 1));
    println!(
        "NLM 512x384 reference={reference:?}, optimized={optimized:?}, speedup={:.2}x",
        reference.as_secs_f64() / optimized.as_secs_f64()
    );
}
