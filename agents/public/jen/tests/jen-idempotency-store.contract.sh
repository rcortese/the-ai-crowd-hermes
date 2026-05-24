#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$ROOT/bin/jen-idempotency-store"
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

out=$($STORE --dir "$DIR" put --kind intent --key k1 --normalized-hash h1 --ttl 7d --status planned --user-ref u --channel-ref c --target-system todoist --audit-log-ref audit1 --result-json '{"ok":true}')
jq -e '.status == "ok" and .kind == "intent" and .key == "k1" and .expires_at != null' <<<"$out" >/dev/null

check=$($STORE --dir "$DIR" check --kind intent --key k1 --normalized-hash h1)
jq -e '.status == "duplicate" and .record.result.ok == true' <<<"$check" >/dev/null

collision=$($STORE --dir "$DIR" check --kind intent --key k1 --normalized-hash different)
jq -e '.status == "collision" and .record.normalized_hash == "h1"' <<<"$collision" >/dev/null

put_collision=$($STORE --dir "$DIR" put --kind intent --key k1 --normalized-hash different --ttl 7d --status planned)
jq -e '.status == "collision"' <<<"$put_collision" >/dev/null

after_collision=$($STORE --dir "$DIR" get --kind intent --key k1)
jq -e '.status == "hit" and .record.status == "collision"' <<<"$after_collision" >/dev/null

set +e
miss=$($STORE --dir "$DIR" get --kind message --key missing)
miss_status=$?
set -e
[[ "$miss_status" == 1 ]]
jq -e '.status == "miss"' <<<"$miss" >/dev/null

echo 'idempotency store tests passed'
