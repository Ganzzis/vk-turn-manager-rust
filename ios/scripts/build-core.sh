#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $(uname -s) != Darwin ]]; then
  echo 'An Xcode macOS host is required to build the iOS libraries.' >&2
  exit 1
fi
sim_arch=$(uname -m)
case "$sim_arch" in
  arm64) sim=aarch64-apple-ios-sim ;;
  x86_64) sim=x86_64-apple-ios ;;
  *) echo 'Unsupported simulator host architecture.' >&2; exit 1 ;;
esac
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CARGO_TARGET_DIR="$PWD/build/cargo"
rustup target add aarch64-apple-ios "$sim"
for target in aarch64-apple-ios "$sim"; do
  platform=iphoneos
  if [[ $target == "$sim" ]]; then platform=iphonesimulator; fi
  SDKROOT=$(xcrun --sdk "$platform" --show-sdk-path) \
    cargo build --manifest-path Core/Cargo.toml --release --locked --target "$target"
  mkdir -p "build/rust/$platform"
  cp "$CARGO_TARGET_DIR/$target/release/libvk_mobile_core.a" "build/rust/$platform/"
done
