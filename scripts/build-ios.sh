#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS and Xcode required'; exit 1; }
target=aarch64-apple-ios
sdk=iphoneos
destination='generic/platform=iOS'
if [[ "${1:-device}" == simulator ]]; then
  sdk=iphonesimulator
  destination='generic/platform=iOS Simulator'
  if [[ "$(uname -m)" == arm64 ]]; then target=aarch64-apple-ios-sim; else target=x86_64-apple-ios; fi
fi
rustup target add "$target"
cargo test --manifest-path core/Cargo.toml --locked --offline
cargo build --manifest-path core/Cargo.toml --locked --offline --release --target "$target"
mkdir -p "build/rust/$sdk"
cp "core/target/$target/release/libhyabrid_core.a" "build/rust/$sdk/"
xcodegen generate
xcodebuild -project HyabridCam.xcodeproj -scheme HyabridCam -configuration Release \
  -sdk "$sdk" -destination "$destination" -derivedDataPath build/xcode \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
if [[ "$sdk" == iphoneos ]]; then
  # Rebuild only our own staging folder, never a computed parent directory.
  rm -rf build/package
  mkdir -p build/package/Payload
  cp -R build/xcode/Build/Products/Release-iphoneos/HyabridCam.app build/package/Payload/
  (cd build/package && zip -qr ../HyabridCam-unsigned.ipa Payload)
  shasum -a 256 build/HyabridCam-unsigned.ipa > build/HyabridCam-unsigned.ipa.sha256
fi
