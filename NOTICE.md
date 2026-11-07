# Notices

This new Rust/Swift implementation is licensed GPL-3.0-or-later.

The reference Android application is Open Camera by Mark Harman, version 1.56.2,
commit 0dd4cbe78872df2c6e4eb6cee3fb0d5637b0f52e, plus local HyabridCam changes:
https://sourceforge.net/p/opencamera/code/

No Android source files, photos, model weights, private account data or signing
credentials are included in this repository. No camera output is uploaded by the app.

The XcodeGen/unsigned-IPA build approach was informed by Hoang Nguyen Duy's
MIT-licensed template: https://github.com/hoangnd107/ios-swiftui-app-template.
The workflow and app sources here were independently written for Rust integration;
no template source/assets were copied. If any template files are imported later,
their MIT copyright/license notice must be retained.

Future imports of ncnn, RealESRGAN and AMD FSR must retain their respective notices.
These libraries/models are not currently linked or bundled.
