#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

directory=${1:?Specify the installation directory}
expected=${2:?Specify the release SHA-256}
binary=$directory/vk-turn-manager
backup=$binary.bak

# Lock the directory inode without leaving a lock file behind.
exec 9< "$directory"
if ! flock -x -w 30 9; then
  echo 'Could not acquire the deployment lock.' >&2
  exit 1
fi

for path in "$binary" "$backup"; do
  if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
    echo 'The manager or backup path is not a regular file.' >&2
    exit 1
  fi
done

stage=$(mktemp -d -- "$directory/.vk-turn-manager.XXXXXXXX")
rollback=false
cleanup() {
  local result=$?
  trap '' HUP INT TERM
  if $rollback; then
    if [[ -e $stage/previous ]]; then
      if [[ ! $binary -ef $stage/previous ]] && ! mv -fT -- "$stage/previous" "$binary"; then
        echo "Rollback failed. The original binary is at $stage/previous." >&2
        exit 1
      fi
      echo 'Restored the previous manager binary.' >&2
    elif ! rm -f -- "$binary"; then
      echo 'Rollback failed while removing the first installation.' >&2
      exit 1
    else
      echo 'Removed the failed first installation.' >&2
    fi
  fi
  rm -rf -- "$stage"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$stage/release"
digest=$(sha256sum < "$stage/release")
if [[ ${digest%% *} != "$expected" ]]; then
  echo 'The manager binary failed SHA-256 verification.' >&2
  exit 1
fi
if (( EUID == 0 )); then
  chown root:root -- "$stage/release"
fi
chmod 0755 -- "$stage/release"

if [[ -f $binary ]]; then
  ln -T -- "$binary" "$stage/previous"
fi
rollback=true
mv -fT -- "$stage/release" "$binary"

check() {
  if ! timeout --kill-after=5s 15s "$binary" "$@" </dev/null >/dev/null 2>&1; then
    printf 'Manager check failed (%s).\n' "$*" >&2
    exit 1
  fi
  printf 'Manager check passed (%s).\n' "$*"
}
check --help
check status
check client list

if [[ -e $stage/previous && ! $stage/previous -ef $backup ]]; then
  ln -T -- "$stage/previous" "$stage/backup"
  mv -fT -- "$stage/backup" "$backup"
fi
rollback=false
echo 'Manager CLI deployed successfully.'
