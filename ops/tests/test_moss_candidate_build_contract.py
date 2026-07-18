#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dockerfile = (root / "ops/images/Dockerfile.moss-all-in-one").read_text(encoding="utf-8")
helper = (root / "ops/scripts/build-moss-all-in-one-candidate.sh").read_text(encoding="utf-8")
compose = (root / "compose.yaml").read_text(encoding="utf-8")
smoke = (root / "tests/smoke-deploy.sh").read_text(encoding="utf-8")
manifest = root / "ops/build-inputs/moss-clash-royale-war-bot.sha256"

assert manifest.is_file()
entries = manifest.read_text(encoding="utf-8").splitlines()
assert len(entries) == 2
assert entries[0].endswith("  package.json")
assert entries[1].endswith("  package-lock.json")
assert "COPY --from=clash_royale_build_input package.json" in dockerfile
assert "COPY agents/private/moss/projects/clash-royale-war-bot" not in dockerfile
assert 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"' in helper
assert 'ROOT="$(git rev-parse --show-toplevel)"' not in helper
assert 'BASE_IMAGE="${MOSS_BASE_IMAGE:?set MOSS_BASE_IMAGE to the reviewed immutable Moss base image}"' in helper
assert '--build-arg "MOSS_BASE_IMAGE=$BASE_IMAGE"' in helper
assert "git -C \"$ROOT\" archive --format=tar \"$COMMIT\"" in helper
assert "sha256sum -c \"$CTX/$MANIFEST_REL\"" in helper
assert "--build-context \"clash_royale_build_input=$INPUT_DIR\"" in helper
assert "additional_contexts:" in compose
assert "clash_royale_build_input: ${CLASH_ROYALE_BUILD_INPUT_DIR:-./ops/build-inputs/empty}" in compose
assert "MOSS_BASE_IMAGE: ${MOSS_BASE_IMAGE:?set MOSS_BASE_IMAGE to the reviewed immutable Moss base image}" in compose
assert "ports: !reset []" in smoke
assert 'user: "99:100"' in smoke
assert "networks: !reset [smoke]" in smoke
assert "env_file: !reset []" in smoke
assert "volumes: !override" in smoke
assert "API_SERVER_KEY: moss-smoke-isolated-api-key" in smoke
assert "isolated API key missing from moss container" in smoke
assert "logs moss 2>&1 | grep -Ei 'api.server|api_server|8648|webhook|8644|refus|error'" in smoke
assert "TELEGRAM_BOT_TOKEN: ''" in smoke
assert "created_env_files=()" in smoke
assert 'smoke_runtime_home="$(mktemp -d -t the-ai-crowd-smoke-runtime.XXXXXX)"' in smoke
assert 'mkdir -p "$smoke_runtime_home/logs"' in smoke
assert 'chown 99:100 "$smoke_runtime_home" "$smoke_runtime_home/logs"' in smoke
assert 'export smoke_runtime_home' in smoke
assert 'find "$smoke_runtime_home" -depth -delete' in smoke
assert "for env_file in env/fleet.env env/moss-webui.env env/roy.env; do" in smoke
assert 'rm -f "${created_env_files[@]}"' in smoke
assert 'compose=(docker compose -p "$project" -f compose.yaml -f "$override_out")' in smoke
assert '"${compose[@]}" down --remove-orphans' in smoke
assert 'started=true\n"${compose[@]}" up -d --build moss' in smoke
assert 'curl -fsS http://127.0.0.1:8787/health' in smoke
assert 'curl -fsS http://127.0.0.1:8648/health' in smoke
assert 'curl -fsS http://127.0.0.1:8644/health' not in smoke
assert 'persisted routes and their' in smoke
assert 'http://127.0.0.1:9119/' not in smoke
print("moss-candidate-build-contract: PASS")
