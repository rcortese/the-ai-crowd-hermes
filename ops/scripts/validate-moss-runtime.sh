#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -ne 1 ]]; then
  printf 'usage: %s /absolute/path/to/canonical-moss-runtime\n' "${0##*/}" >&2
  exit 64
fi
runtime=$1
canonical=${MOSS_CANONICAL_RUNTIME:-/mnt/user/appdata/the-ai-crowd/runtime/moss-home}
expected_uid=${MOSS_RUNTIME_EXPECTED_UID:-99}
expected_gid=${MOSS_RUNTIME_EXPECTED_GID:-100}
container=${MOSS_RUNTIME_VALIDATE_CONTAINER-the-ai-crowd-moss-1}
invalid() { printf 'MOSS_RUNTIME_INVALID %s\n' "$*" >&2; exit 1; }
case "$runtime" in /*) ;; *) invalid "path must be absolute: $runtime" ;; esac
case "$canonical" in /*) ;; *) invalid "canonical path must be absolute: $canonical" ;; esac
[[ "$runtime" == "$canonical" ]] || invalid "identity mismatch: expected logical root $canonical, got $runtime"
[[ -d "$runtime" && ! -L "$runtime" ]] || invalid "runtime directory missing or unsafe: $runtime"
[[ -d "$canonical" && ! -L "$canonical" ]] || invalid "canonical directory missing or unsafe: $canonical"
runtime_real=$(realpath -e -- "$runtime") || invalid "cannot resolve runtime: $runtime"
canonical_real=$(realpath -e -- "$canonical") || invalid "cannot resolve canonical runtime: $canonical"
[[ "$runtime_real" == "$canonical_real" ]] || invalid "realpath identity mismatch: expected $canonical_real, got $runtime_real"
metadata=$(stat -Lc '%u:%g:%a' -- "$runtime")
[[ "$metadata" == "$expected_uid:$expected_gid:700" ]] || invalid "runtime metadata mismatch: expected $expected_uid:$expected_gid:700, got $metadata"
for spec in 'config.yaml:660' 'auth.json:600' 'state.db:660'; do
  required=${spec%%:*}; expected_mode=${spec##*:}; path=$runtime/$required
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || invalid "required regular non-empty file: $path"
  metadata=$(stat -Lc '%u:%g:%a' -- "$path")
  [[ "$metadata" == "$expected_uid:$expected_gid:$expected_mode" ]] || invalid "$required metadata mismatch: expected $expected_uid:$expected_gid:$expected_mode, got $metadata"
done
jq -e 'type == "object"' "$runtime/auth.json" >/dev/null || invalid 'auth.json is not a JSON object'
header=$(dd if="$runtime/state.db" bs=15 count=1 2>/dev/null || true)
[[ "$header" == 'SQLite format 3' ]] || invalid 'state.db does not have a SQLite header'
sqlite3 -readonly "$runtime/state.db" 'PRAGMA schema_version;' >/dev/null 2>&1 || invalid 'state.db cannot be opened read-only'
if [[ -n "$container" ]]; then
  docker inspect "$container" >/dev/null 2>&1 || invalid "validation container missing: $container"
  live_source=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/opt/data"}}{{.Source}}{{end}}{{end}}')
  [[ "$live_source" == "$canonical" ]] || invalid "live /opt/data source mismatch: expected $canonical, got ${live_source:-<empty>}"
fi
printf 'MOSS_RUNTIME_VALIDATED canonical=%s real=%s\n' "$canonical" "$canonical_real"
