#!/usr/bin/env bash
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
directory=$scratch/bin
binary=$directory/vk-turn-manager
backup=$binary.bak
log=$scratch/deploy.log
mkdir "$directory"

make_fixture() {
  local path=$1 fail=${2:-}
  {
    printf '#!/usr/bin/env bash\n'
    printf 'test -x "$0" || exit 2\n'
    printf '%s\n' 'case "$*" in --help|status|"client list") ;; *) exit 2 ;; esac'
    printf '%s\n' 'echo synthetic-private-output; echo synthetic-private-error >&2'
    printf '[[ "$*" != %q ]]\n' "$fail"
  } > "$path"
}

deploy() {
  local fixture=$1 digest
  digest=$(sha256sum < "$fixture")
  bash scripts/deploy-manager-install.sh "$directory" "${2:-${digest%% *}}" < "$fixture" > "$log" 2>&1
}

assert_clean() {
  [[ -z $(find "$directory" -name '.vk-turn-manager.*' -print) ]]
  ! grep -Eq 'synthetic-private-(output|error)' "$log" || return 1
}

make_fixture "$scratch/bad" 'client list'
if deploy "$scratch/bad"; then
  echo 'A failed first installation unexpectedly succeeded.' >&2
  exit 1
fi
[[ ! -e $binary && ! -e $backup ]]
assert_clean

make_fixture "$scratch/first"
deploy "$scratch/first"
cmp "$binary" "$scratch/first"
[[ $(stat -c '%a' "$binary") == 755 && ! -e $backup ]]
assert_clean

# Replace an existing binary and keep its exact inode and metadata as backup.
first_inode=$(stat -c '%i' "$binary")
chmod 0710 "$binary"
make_fixture "$scratch/second"
printf '# second release\n' >> "$scratch/second"
deploy "$scratch/second"
cmp "$binary" "$scratch/second"
cmp "$backup" "$scratch/first"
[[ $(stat -c '%a' "$backup") == 710 && $(stat -c '%i' "$backup") == "$first_inode" ]]
[[ $(stat -c '%a %u:%g' "$binary") == "755 $(id -u):$(id -g)" ]]
assert_clean

second_inode=$(stat -c '%i' "$binary")
for command in '--help' status 'client list'; do
  make_fixture "$scratch/bad" "$command"
  if deploy "$scratch/bad"; then
    echo "Deployment unexpectedly passed a failing $command check." >&2
    exit 1
  fi
  grep -Fq "Manager check failed ($command)." "$log"
  cmp "$binary" "$scratch/second"
  cmp "$backup" "$scratch/first"
  [[ $(stat -c '%i' "$binary") == "$second_inode" ]]
  assert_clean
done

if deploy "$scratch/first" "$(printf '%064d' 0)"; then
  echo 'A payload with the wrong digest was accepted.' >&2
  exit 1
fi
grep -Fq 'failed SHA-256 verification' "$log"
[[ $(stat -c '%i' "$binary") == "$second_inode" ]]
cmp "$backup" "$scratch/first"
assert_clean

mv "$binary" "$scratch/saved"
ln -s "$scratch/saved" "$binary"
if deploy "$scratch/first"; then
  echo 'A symlink at the installation path was accepted.' >&2
  exit 1
fi
[[ -L $binary ]]
cmp "$scratch/saved" "$scratch/second"
assert_clean
# Exercise the SSH command and stdin transfer without connecting to a server.
rm -- "$binary"
mkdir "$scratch/mock-bin"
cat > "$scratch/mock-bin/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
set -euo pipefail
strict=false
pinned=false
while [[ $1 != -- ]]; do
  case $1 in
    -T) shift ;;
    -F) [[ $2 == /dev/null ]]; shift 2 ;;
    -i)
      [[ $(stat -c %a "$2") == 600 && $(cat "$2") == synthetic-key ]]
      shift 2
      ;;
    -o)
      case $2 in
        StrictHostKeyChecking=yes) strict=true ;;
        UserKnownHostsFile=*)
          hosts=${2#*=}
          [[ $(stat -c %a "$hosts") == 600 && $(cat "$hosts") == synthetic-host-key ]]
          pinned=true
          ;;
      esac
      shift 2
      ;;
    *) exit 2 ;;
  esac
done
[[ $strict == true && $pinned == true ]]
[[ $2 == test-user@test.example && -z ${VPS_SSH_KEY+x} && -z ${VPS_KNOWN_HOSTS+x} ]]
printf '%s\n' "${hosts%/*}" > "$MOCK_SSH_SCRATCH"
sh -c "$3"
MOCK_SSH
cat > "$scratch/mock-bin/sudo" <<'MOCK_SUDO'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == '-n -u root -g root -- /bin/bash -c '* ]]
shift 7
[[ $# == 5 && $1 == -c && $3 == deploy-manager && $4 == /usr/local/bin ]]
exec /bin/bash -c "$2" "$3" "$MOCK_REMOTE_DIRECTORY" "$5"
MOCK_SUDO
chmod 0700 "$scratch/mock-bin/"*
digest=$(sha256sum < "$scratch/second")
PATH="$scratch/mock-bin:$PATH" MOCK_REMOTE_DIRECTORY="$directory" \
  MOCK_SSH_SCRATCH="$scratch/ssh-scratch" VPS_USER=test-user VPS_HOST=test.example \
  VPS_SSH_KEY=synthetic-key VPS_KNOWN_HOSTS=synthetic-host-key MANAGER_SHA256="${digest%% *}" \
  bash scripts/deploy-manager-ssh.sh "$scratch/second" > "$log" 2>&1
cmp "$binary" "$scratch/second"
[[ ! -e $(cat "$scratch/ssh-scratch") ]]
assert_clean
echo 'Manager deployment and rollback tests passed.'
