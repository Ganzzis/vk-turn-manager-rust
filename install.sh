#!/usr/bin/env bash
set -euo pipefail

mode=${1:-install}
version=${2:-v0.3.0}
local_bundle=${3:-}
if (( $# > 3 )) || [[ $mode != install && $mode != update ]] || [[ ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Использование: sudo bash install.sh [install|update] [v0.3.0] [каталог артефактов]' >&2
  exit 2
fi
if (( EUID != 0 )); then
  echo 'Запустите установщик через sudo.' >&2
  exit 1
fi
# shellcheck source=/dev/null
. /etc/os-release
if [[ $ID != ubuntu || ( $VERSION_ID != 24.04 && $VERSION_ID != 26.04 ) ]]; then
  echo 'Поддерживаются Ubuntu 24.04 и 26.04.' >&2
  exit 1
fi
case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo 'Поддерживаются amd64 и arm64.' >&2; exit 1 ;;
esac

name="vk-turn-manager-$version-linux-$arch"
archive=$name.tar.gz
umask 077
scratch=$(mktemp -d)
staged=
cleanup() {
  rm -rf -- "$scratch"
  if [[ -n $staged ]]; then rm -f -- "$staged"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n $local_bundle ]]; then
  cp -- "$local_bundle/SHA256SUMS" "$local_bundle/$archive" "$scratch/"
else
  base="https://github.com/Ganzzis/vk-turn-manager-rust/releases/download/$version"
  for file in SHA256SUMS "$archive"; do
    curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 120 --output "$scratch/$file" "$base/$file"
  done
fi
(
  cd "$scratch"
  digest=$(awk -v file="$archive" '$2 == file || $2 == "*" file { print $1 }' SHA256SUMS)
  [[ $digest =~ ^[a-fA-F0-9]{64}$ ]]
  printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status
  tar --extract --gzip --to-stdout --file "$archive" -- "$name/vk-turn-manager" > vk-turn-manager
)
chmod 0700 "$scratch/vk-turn-manager"
[[ $("$scratch/vk-turn-manager" --version) == "vk-turn-manager ${version#v}" ]]

directory=/usr/local/bin
target=$directory/vk-turn-manager
exec 9< "$directory"
flock -x -w 30 9
if [[ -L $target || ( -e $target && ! -f $target ) ]]; then
  echo "Ожидался обычный файл по пути $target." >&2
  exit 1
fi
staged=$(mktemp "$directory/.vk-turn-manager.XXXXXXXX")
install -o root -g root -m 0755 "$scratch/vk-turn-manager" "$staged"
if [[ $mode == install ]]; then
  if ! "$staged" setup; then
    # Keep a management CLI available if the new server needs NAT repair.
    if [[ ! -e $target && -f /etc/vk-turn-manager/managed ]]; then
      mv -fT -- "$staged" "$target"
    fi
    exit 1
  fi
else
  "$staged" reinstall
fi
mv -fT -- "$staged" "$target"
printf 'Меню: sudo %s\n' "$target"
