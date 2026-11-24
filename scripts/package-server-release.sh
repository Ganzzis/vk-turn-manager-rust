#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

target=${1:?Specify the Rust target}
output=${2:?Specify the output directory}
case "$target:$(uname -m)" in
  x86_64-unknown-linux-gnu:x86_64) arch=amd64 ;;
  aarch64-unknown-linux-gnu:aarch64) arch=arm64 ;;
  *) echo 'Expected a supported native Linux target (amd64 or arm64).' >&2; exit 2 ;;
esac
[[ $(uname -s) == Linux ]]

mkdir -p "$output"
output=$(cd "$output" && pwd)
cd "$(dirname "$0")/.."
version=$(cargo +1.100.0 metadata --format-version 1 --locked --no-deps |
  python3 -c 'import json, sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"] == "vk-turn-manager"))')
if [[ ${GITHUB_REF_TYPE:-} == tag ]]; then
  if [[ ${GITHUB_REF_NAME:-} != "v$version" ]] || ! git merge-base --is-ancestor HEAD origin/main; then
    echo 'The release tag must match Cargo.toml and point to a commit on main.' >&2
    exit 1
  fi
fi

export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct HEAD)
cargo_dir=${CARGO_HOME:-$HOME/.cargo}
# Keep absolute checkout and registry paths out of the compiled artifact.
printf -v CARGO_ENCODED_RUSTFLAGS '%s\x1f%s\x1f%s\x1f%s' \
  --remap-path-prefix "$PWD=/build/source" \
  --remap-path-prefix "$cargo_dir=/build/cargo"
export CARGO_ENCODED_RUSTFLAGS
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"
cargo +1.100.0 build --locked --release --target "$target"
binary="$CARGO_TARGET_DIR/$target/release/vk-turn-manager"
[[ $("$binary" --version) == "vk-turn-manager $version" ]]

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
name="vk-turn-manager-v$version-linux-$arch"
install -d -m 0755 "$stage/$name"
install -m 0755 "$binary" "$stage/$name/vk-turn-manager"
install -m 0644 LICENSE README.md CHANGELOG.md install.sh "$stage/$name"
tar --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
  --owner=0 --group=0 --numeric-owner -C "$stage" -cf - "$name" |
  gzip -n > "$stage/$name.tar.gz"
mv "$stage/$name.tar.gz" "$output/$name.tar.gz"
