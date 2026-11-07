# HyabridCam for iPhone — Rust + Swift

An **early, unverified-on-device port** of the HyabridCam/Open Camera workflow.
This is not feature-complete Open Camera for iOS. Do not treat a successful build
as a camera-quality or device-compatibility test.

## Architecture

- `core/`: dependency-free Rust static library. Translation registration, rejected-frame
  fallback, linear-light NR averaging, exposure fusion, 3×3-patch/7×7-search CPU NLM,
  mild dehaze, contrast, saturation, temperature and bounded unsharp masking.
- `bridge/`: documented C ABI, owned processing context and independent atomic cancel token.
- `App/`: SwiftUI, AVFoundation camera/microphone, Photos storage and PhotosPicker import.
  Captured JPEG and DNG originals are retained in app Documents/Captures before processing.
- `scripts/build-ios.sh`: Rust + XcodeGen + unsigned Xcode build and IPA packaging.
- `.github/workflows/ios-build.yml`: macOS build, Rust unit tests, device and simulator compilation.

The original Android app is Mark Harman Open Camera 1.56.2 plus HyabridCam additions.
Android Camera2 and its UI cannot execute on iOS. This port replaces platform-specific
parts with AVFoundation and SwiftUI. Vulkan/Java code is not represented as working Metal code.

## Build without owning a Mac

Use **Actions → Build HyabridCam iOS (unsigned) → Run workflow**. A successful job
provides `HyabridCam-unsigned` with an IPA and SHA-256. The IPA is not signed or
installable directly. Sideloadly on Windows signs and installs it using your Apple Account.
Keep Apple credentials on the signing computer; this workflow does not need them.

Standard macOS runners in public repositories are free under GitHub's applicable
Actions rules. Private repositories have plan-specific usage allowances and billing.
Free Apple provisioning expires after 7 days; automatic re-signing still uses that limit.
Sideloadly's Windows prerequisites differ from Apple's Devices app; follow its official FAQ.

The iOS deployment target is 17.0. The target device is iPhone 13 Pro Max on iOS 18.7.7 (22H340),
as reported by the user. RAW support is checked at runtime for the selected physical lens.
The capture path deliberately does not require ProRAW or a Pro-model phone.

## Local checks on Windows (all writes on D:)

```powershell
$env:CARGO_HOME='D:\DevTools\Rust\cargo'
$env:RUSTUP_HOME='D:\DevTools\Rust\rustup'
$env:TEMP='D:\DevTools\Temp'
$env:TMP=$env:TEMP
& "$env:CARGO_HOME\bin\cargo.exe" test --manifest-path core/Cargo.toml --locked --offline
& "$env:CARGO_HOME\bin\cargo.exe" clippy --manifest-path core/Cargo.toml --all-targets --offline -- -D warnings
```

On a Mac with Rust and XcodeGen: `bash scripts/build-ios.sh device` or `simulator`.
Rust 1.85.0 is used in CI; the initial Windows checks used Rust 1.99.0.

## Current limits

See `FEATURES.md` for parity status. In particular, **RAW burst SR ×2, AMD RCAS and
RealESRGAN are deferred at the user’s request and not implemented**. The sharpening control is ordinary unsharp masking.
HDR brightness equalization uses 3/5/7 JPEG exposures, EXIF shutter × ISO normalization,
clipped-sample rejection and a shared tone curve. Range: auto or ±2/3/4 EV, clamped to
hardware limits. The sRGB approximation is not a calibrated RAW pipeline or Apple Smart HDR.
Missing exposure metadata stops processing and retains originals.
Only integer translation is handled; camera rotation, parallax and local motion can
cause rejection, blur or ghosts. No crop or digital zoom is introduced by fusion.

Rust input is bounded to 13 million pixels per image and 7 images; no hidden downscale.
CPU NLM is a reference implementation and can take a long time at full resolution.
Registration is bounded to ±12 pixels in the app. Seven frames require hundreds of MB.
No low-memory-device performance or camera output quality has been measured.

Original files in app Documents grow with use. They are accessible through Files/file
sharing; remove captures you no longer need. Removing the app deletes its Documents.
Processed PNGs are sRGB without copied source EXIF; original JPEG/DNG files preserve
their original bytes. A Photos permission/save failure does not delete captured originals.

## License and sources

GPL-3.0-or-later; see `LICENSE` and `NOTICE.md`. The CI design follows the approach
demonstrated by [hoangnd107/ios-swiftui-app-template](https://github.com/hoangnd107/ios-swiftui-app-template).
No template app source or assets have been copied.

References: [Apple AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app),
[GitHub runners](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job),
[Apple Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account),
[Sideloadly FAQ](https://sideloadly.io/faq.html).
