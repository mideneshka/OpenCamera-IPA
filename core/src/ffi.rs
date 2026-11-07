// SPDX-License-Identifier: GPL-3.0-or-later
//! C ABI. Handles must be used on one worker thread, except cancellation.
//! Callers own all input buffers and must supply valid lengths/lifetimes.
use crate::*;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub struct Context {
    frames: Vec<Image>,
    output: Option<Image>,
    report: Vec<Alignment>,
    cancel: Arc<AtomicBool>,
}
fn code(result: Result<()>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(Error::Dimensions) => 1,
        Err(Error::Parameters) => 2,
        Err(Error::Memory) => 3,
        Err(Error::Cancelled) => 4,
        Err(Error::NoFrames) => 5,
    }
}
fn guard(f: impl FnOnce() -> Result<()>) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).map(code).unwrap_or(6)
}
#[no_mangle]
pub extern "C" fn hc_create() -> *mut Context {
    Box::into_raw(Box::new(Context {
        frames: Vec::new(),
        output: None,
        report: Vec::new(),
        cancel: Arc::new(AtomicBool::new(false)),
    }))
}
/// # Safety
/// ctx must be null or a live handle from hc_create, destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn hc_destroy(ctx: *mut Context) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}
/// # Safety
/// ctx must be live; no concurrent destruction or mutation except hc_cancel.
#[no_mangle]
pub unsafe extern "C" fn hc_reset(ctx: *mut Context) -> i32 {
    guard(|| {
        let c = ctx.as_mut().ok_or(Error::Parameters)?;
        c.frames.clear();
        c.output = None;
        c.report.clear();
        c.cancel.store(false, Ordering::Relaxed);
        Ok(())
    })
}
/// # Safety
/// ctx must be valid and accessed serially. Returned token expires with ctx.
#[no_mangle]
pub unsafe extern "C" fn hc_cancel_token(ctx: *const Context) -> *const AtomicBool {
    ctx.as_ref()
        .map(|c| Arc::as_ptr(&c.cancel))
        .unwrap_or(std::ptr::null())
}
/// # Safety
/// token is from hc_cancel_token; context stays alive until this call returns.
/// Independent allocation avoids aliasing the mutable processing context.
#[no_mangle]
pub unsafe extern "C" fn hc_cancel(token: *const AtomicBool) {
    if let Some(flag) = token.as_ref() {
        flag.store(true, Ordering::Relaxed);
    }
}
/// # Safety
/// data points to len readable bytes, no aliasing with ctx; serial worker access.
#[no_mangle]
pub unsafe extern "C" fn hc_add_rgba(
    ctx: *mut Context,
    w: u32,
    h: u32,
    data: *const u8,
    len: usize,
) -> i32 {
    guard(|| {
        let c = ctx.as_mut().ok_or(Error::Parameters)?;
        let n = image_len(w as usize, h as usize)?;
        if data.is_null() || len != n || c.frames.len() >= 7 {
            return Err(Error::Parameters);
        }
        if let Some(a) = c.frames.first() {
            if a.width != w as usize || a.height != h as usize {
                return Err(Error::Dimensions);
            }
        }
        let mut pixels = buffer(n)?;
        pixels.copy_from_slice(std::slice::from_raw_parts(data, n));
        c.frames.push(Image::new(w as usize, h as usize, pixels)?);
        Ok(())
    })
}
/// # Safety
/// Valid handle and readable settings; no concurrent calls except hc_cancel.
/// mode: 0 single/editor, 1 NR, 2 exposure fusion (not linear-radiance HDR).
#[no_mangle]
pub unsafe extern "C" fn hc_run(
    ctx: *mut Context,
    mode: u32,
    radius: i32,
    settings: *const Adjustments,
) -> i32 {
    guard(|| {
        let c = ctx.as_mut().ok_or(Error::Parameters)?;
        c.output = None;
        c.report.clear();
        let settings = *settings.as_ref().ok_or(Error::Parameters)?;
        settings.validate()?;
        let stop = || c.cancel.load(Ordering::Relaxed);
        let result = match mode {
            0 => process(c.frames.first().ok_or(Error::NoFrames)?, settings, &stop)?,
            1 | 2 => {
                let fused = fuse(
                    &c.frames,
                    if mode == 1 {
                        FusionMode::NoiseReduction
                    } else {
                        FusionMode::ExposureFusion
                    },
                    radius,
                    &stop,
                )?;
                c.report = fused.alignments;
                process(&fused.image, settings, &stop)?
            }
            _ => return Err(Error::Parameters),
        };
        c.output = Some(result);
        Ok(())
    })
}
/// # Safety
/// out points to capacity writable bytes and must not overlap ctx or its images.
#[no_mangle]
pub unsafe extern "C" fn hc_copy_output(ctx: *const Context, out: *mut u8, capacity: usize) -> i32 {
    guard(|| {
        let c = ctx.as_ref().ok_or(Error::Parameters)?;
        let image = c.output.as_ref().ok_or(Error::NoFrames)?;
        if out.is_null() || capacity < image.pixels.len() {
            return Err(Error::Dimensions);
        }
        std::ptr::copy_nonoverlapping(image.pixels.as_ptr(), out, image.pixels.len());
        Ok(())
    })
}
/// # Safety
/// out points to capacity writable hc_alignment entries; valid serial handle.
#[no_mangle]
pub unsafe extern "C" fn hc_copy_report(
    ctx: *const Context,
    out: *mut Alignment,
    capacity: usize,
) -> i32 {
    guard(|| {
        let c = ctx.as_ref().ok_or(Error::Parameters)?;
        if out.is_null() || capacity < c.report.len() {
            return Err(Error::Dimensions);
        }
        std::ptr::copy_nonoverlapping(c.report.as_ptr(), out, c.report.len());
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn abi_roundtrip_and_small_output_rejection() {
        unsafe {
            let c = hc_create();
            let input = [90, 100, 110, 255].repeat(64);
            assert_eq!(hc_add_rgba(c, 8, 8, input.as_ptr(), input.len()), 0);
            assert_eq!(hc_run(c, 0, 2, &Adjustments::default()), 0);
            let mut out = vec![0; input.len()];
            assert_eq!(hc_copy_output(c, out.as_mut_ptr(), 1), 1);
            assert_eq!(hc_copy_output(c, out.as_mut_ptr(), out.len()), 0);
            assert_eq!(out, input);
            hc_cancel(hc_cancel_token(c));
            assert_eq!(hc_run(c, 0, 2, &Adjustments::default()), 4);
            assert_eq!(hc_copy_output(c, out.as_mut_ptr(), out.len()), 5);
            assert_eq!(hc_reset(c), 0);
            hc_destroy(c);
        }
    }
    #[test]
    fn null_and_bad_lengths_rejected() {
        unsafe {
            assert_eq!(hc_reset(std::ptr::null_mut()), 2);
            let c = hc_create();
            let p = [0u8; 16];
            assert_eq!(hc_add_rgba(c, 2, 2, p.as_ptr(), 15), 2);
            assert_eq!(hc_run(c, 9, 1, &Adjustments::default()), 2);
            hc_destroy(c);
        }
    }
}
