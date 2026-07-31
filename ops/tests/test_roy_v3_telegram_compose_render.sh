#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE="$ROOT/compose.yaml"
command -v docker >/dev/null
command -v jq >/dev/null

tmp=$(mktemp -d "${TMPDIR:-/tmp}/roy-telegram-compose-render.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
chmod 700 "$tmp"
cp "$COMPOSE" "$tmp/compose.yaml"
mkdir -m 700 "$tmp/env"

# Compose requires env_file paths to exist even when the target service does not
# consume their values. Create empty synthetic files only inside this fixture.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p "$tmp/$(dirname "$rel")"
  : >"$tmp/$rel"
done < <(grep -oE '\./env/[A-Za-z0-9._-]+' "$COMPOSE" | sort -u)

# Satisfy every fail-closed interpolation with synthetic values, then install a
# deliberately broader historical allowlist that must not affect Roy's rendered
# TELEGRAM_ALLOWED_USERS value.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s=fixture-%s\n' "$name" "${name,,}"
done < <(grep -oE '\$\{[A-Z0-9_]+:\?' "$COMPOSE" | sed -E 's/^\$\{//; s/:\?$//' | sort -u) >"$tmp/.env"
cat >>"$tmp/.env" <<'EOF'
ROY_TELEGRAM_BOT_TOKEN=fixture-bot-token
ROY_TELEGRAM_HOME_CHANNEL=424242
ROY_TELEGRAM_ALLOWED_USERS=111111,222222
ROY_TELEGRAM_HOME_CHANNEL_THREAD_ID=
EOF
chmod 600 "$tmp/.env"

docker compose \
  --project-directory "$tmp" \
  --env-file "$tmp/.env" \
  -f "$tmp/compose.yaml" \
  config --format json >"$tmp/rendered.json"

jq -e '
  .services.roy.environment.TELEGRAM_BOT_TOKEN == "fixture-bot-token" and
  .services.roy.environment.TELEGRAM_ALLOWED_USERS == "424242" and
  .services.roy.environment.TELEGRAM_HOME_CHANNEL == "424242" and
  (.services.roy.environment.TELEGRAM_ALLOWED_USERS | contains(",") | not) and
  (.services.roy.environment | has("ROY_TELEGRAM_ALLOWED_USERS") | not) and
  (.services.roy.environment | has("TELEGRAM_ALLOW_ALL_USERS") | not) and
  ([.services.roy.environment | keys[] | select(test("ALLOWED_CHATS|GROUP_ALLOWED|ALLOW_ALL"))] | length == 0)
' "$tmp/rendered.json" >/dev/null

printf 'ROY_TELEGRAM_RENDER_TEST=PASS\n'
