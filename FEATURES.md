# Feature parity ledger — 2026-11-07

`Source written` means source code exists, **not** that it was compiled for iOS or
tested with a real camera. This ledger deliberately distinguishes implementation
from verification. The target is the user's HyabridCam fork, including upstream
Open Camera functionality; no claim of complete parity is made.

| Function | Rust / iOS implementation | Verification / remaining work |
|---|---|---|
| Camera preview, tap focus, physical lens switch | Swift AVFoundation | Source written; device test pending |
| Photo JPEG, flash, digital zoom | Swift AVFoundation | Source written; preview/photo field of view must be tested |
| Bayer RAW + JPEG pair | AVFoundation RAW format query, DNG original retained | Source written; lens/device support pending |
| NR 3/5/7-frame sequence | Sequential capture, locked exposure/focus/WB; Rust registration/fusion | Rust synthetic tests; capture not verified |
| HDR 3/5/7 frames and ±2/3/4 EV | Sequential bias requests, EXIF exposure normalization, Rust tone mapping | Synthetic shadow/highlight tests for 3/5/7 pass; camera test pending |
| Integer translation, reject unrelated frames | Rust normalized correlation | Known-shift, flat-image, unrelated-image tests pass |
| Deghosting | NR local luminance rejection only | No full optical flow, rotation, parallax or HDR deghosting |
| NLM | Rust CPU reference, patch3/search7 | Synthetic flat-noise test; performance unmeasured |
| Dehaze, contrast, saturation, temperature | Rust linear-light adjustments | Identity and temperature tests; device quality unmeasured |
| Sharpening | Rust bounded unsharp mask | Not AMD RCAS; no equivalence claim |
| Manual ISO / shutter / focus / WB / EV | Swift AVFoundation, hardware-clamped | Source written; exposure restoration needs real-device check |
| Timer 0/3/5/10 seconds, grid | SwiftUI | Source written |
| Persistent capture/processing preferences | AppStorage | Source written; selected lens not persisted yet |
| Import image → processing → separate PNG | PhotosPicker + Rust | Source written; metadata/orientation test pending |
| Video + microphone | AVCaptureMovieFileOutput | Source written; default high preset, no advanced video controls |
| Save to Photos, retain capture originals | Swift Photos + app Documents | Source written; permission/error paths need device tests |
| Cancellation | Rust atomic token + capture sequence cancellation | Rust ABI tests; UI cancellation test pending |
| Camera resolution / aspect-ratio picker | Not implemented | Enumerate device formats and photo dimensions |
| High-resolution native 24/48 MP and ProRAW | Not implemented | Capability query, memory policy and device validation |
| RAW 5/7-frame SR ×2 | Deferred by user | Port CFA/black-white levels/WB/CCM and reconstruction; Metal backend |
| FSR1 RCAS | Not implemented | Preserve AMD license and compare shader outputs |
| RealESRGAN_x4plus → ×2/×4 | Deferred by user | ncnn Metal/CoreML backend choice, model conversion and numerical parity |
| Focus bracketing, panorama, DRO, fast burst | Not implemented | Separate capture/processing workflows |
| Video FPS/codec/bitrate, slow motion, timelapse, stabilization | Not implemented | AVFoundation format selection and real-device checks |
| Video pause/resume, snapshots during video | Not implemented | Requires dedicated recording pipeline |
| Histograms, zebra, focus peaking, level/compass | Not implemented | VideoDataOutput + overlays/sensors |
| Geotagging, stamps, metadata controls | Not implemented | Location permission and export metadata pipeline |
| Audio/remote/volume-button trigger, lock-screen extension | Not implemented | iOS supported event/extension APIs; no Android service equivalents |
| Full upstream settings UI and accessibility/localizations | Partial | Inventory source preferences and port supported controls |

The first shipping milestone must pass: IPA compile; launch; permission grant/deny;
each physical lens; portrait photo matching preview; raw files open in an independent
decoder; video has audio; NR/HDR source count and FOV; memory/thermal soak; cancellation;
lock/background/resume; Photos failure preserves originals. None of these device checks
has been declared passed before running on the actual iPhone.
