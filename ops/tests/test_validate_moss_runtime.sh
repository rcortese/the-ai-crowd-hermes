#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT=${1:-ops/scripts/validate-moss-runtime.sh}
SCRIPT=$(realpath -m "$SCRIPT")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
uid=$(id -u); gid=$(id -g)
canonical=$tmp/canonical; snapshot=$tmp/snapshot; dev=$tmp/dev
make_runtime() {
  local root=$1
  mkdir -p "$root"; chmod 700 "$root"
  printf 'model: fixture\n' > "$root/config.yaml"
  printf '{}\n' > "$root/auth.json"
  sqlite3 "$root/state.db" 'CREATE TABLE fixture(id INTEGER);'
  chmod 660 "$root/config.yaml" "$root/state.db"; chmod 600 "$root/auth.json"
}
make_runtime "$canonical"; make_runtime "$snapshot"; make_runtime "$dev"
run_validator() {
  MOSS_CANONICAL_RUNTIME="$canonical" MOSS_RUNTIME_EXPECTED_UID="$uid" MOSS_RUNTIME_EXPECTED_GID="$gid" MOSS_RUNTIME_VALIDATE_CONTAINER= "$SCRIPT" "$@"
}
expect_rejected() {
  local path=$1 expected=$2 output rc
  set +e; output=$(run_validator "$path" 2>&1); rc=$?; set -e
  [[ $rc -ne 0 ]]; [[ "$output" == *"$expected"* ]]
}
output=$(run_validator "$canonical")
[[ "$output" == MOSS_RUNTIME_VALIDATED\ canonical=* ]]
expect_rejected "$snapshot" 'identity mismatch'
expect_rejected "$dev" 'identity mismatch'
expect_rejected relative-runtime 'path must be absolute'
cp "$canonical/auth.json" "$canonical/auth.json.saved"; printf 'not-json\n' > "$canonical/auth.json"
expect_rejected "$canonical" 'auth.json is not a JSON object'; mv "$canonical/auth.json.saved" "$canonical/auth.json"
cp "$canonical/state.db" "$canonical/state.db.saved"; printf 'not sqlite\n' > "$canonical/state.db"; chmod 660 "$canonical/state.db"
expect_rejected "$canonical" 'SQLite header'; mv "$canonical/state.db.saved" "$canonical/state.db"
chmod 755 "$canonical"; expect_rejected "$canonical" 'runtime metadata mismatch'; chmod 700 "$canonical"
ln -s "$canonical" "$tmp/canonical-link"
set +e
output=$(MOSS_CANONICAL_RUNTIME="$tmp/canonical-link" MOSS_RUNTIME_EXPECTED_UID="$uid" MOSS_RUNTIME_EXPECTED_GID="$gid" MOSS_RUNTIME_VALIDATE_CONTAINER= "$SCRIPT" "$tmp/canonical-link" 2>&1); rc=$?
set -e
[[ $rc -ne 0 && "$output" == *'runtime directory missing or unsafe'* ]]
printf 'validate-moss-runtime-tests: PASS\n'
