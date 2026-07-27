#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dockerfile = (root / "ops/images/Dockerfile.moss-all-in-one").read_text(encoding="utf-8")
helper = (root / "ops/scripts/build-moss-all-in-one-candidate.sh").read_text(encoding="utf-8")
overlay = (root / "ops/images/Dockerfile.moss-a2a-overlay").read_text(encoding="utf-8")
roy_supervisor = (root / "ops/images/roy-all-in-one.supervisor.conf").read_text(encoding="utf-8")
overlay_helper = (root / "ops/scripts/build-moss-a2a-overlay-candidate.sh").read_text(encoding="utf-8")
runtime_overlay = (root / "ops/images/Dockerfile.runtime-a2a-overlay").read_text(encoding="utf-8")
runtime_overlay_helper = (root / "ops/scripts/build-runtime-a2a-overlay-candidate.sh").read_text(encoding="utf-8")
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
for runtime_path in (
    "/opt/hermes/gateway/persona_api.py",
    "/opt/hermes/gateway/readiness.py",
    "/opt/hermes/gateway/platforms/api_server.py",
    "/opt/hermes/tools/environments/local.py",
    "/opt/hermes/tools/persona_rpc.py",
    "/opt/hermes/toolsets.py",
):
    assert runtime_path in overlay
    assert runtime_path in runtime_overlay
assert 'CURRENT_TAG="${CURRENT_MOSS_IMAGE:?set CURRENT_MOSS_IMAGE to the reviewed current all-in-one image tag}"' in overlay_helper
assert 'EXPECTED_CURRENT_ID="${CURRENT_MOSS_IMAGE_ID:?set CURRENT_MOSS_IMAGE_ID to its immutable image ID}"' in overlay_helper
assert 'docker image inspect "$CURRENT_TAG"' in overlay_helper
assert 'docker image inspect "$HERMES_TAG"' in overlay_helper
assert 'case "$PERSONA" in' in runtime_overlay_helper
assert 'moss|roy)' in runtime_overlay_helper
assert 'jen|denholm|richmond|the-elders)' in runtime_overlay_helper
assert 'DOCKERFILE=ops/images/Dockerfile.moss-a2a-overlay' in runtime_overlay_helper
assert 'DOCKERFILE=ops/images/Dockerfile.runtime-a2a-overlay' in runtime_overlay_helper
assert 'CURRENT_IMAGE_ARG=CURRENT_MOSS_IMAGE' in runtime_overlay_helper
assert 'CURRENT_IMAGE_ARG=CURRENT_RUNTIME_IMAGE' in runtime_overlay_helper
assert 'CURRENT_IMAGE_ARG=$CURRENT_IMAGE_ARG' not in runtime_overlay_helper
assert '"$CURRENT_IMAGE_ARG=$CURRENT_TAG"' in runtime_overlay_helper
assert 'RUNTIME_PERSONA=$PERSONA' in runtime_overlay_helper
assert 'the-ai-crowd.current-runtime-base-id=$EXPECTED_CURRENT_ID' in runtime_overlay_helper
assert 'CMD ["gateway", "run"]' in runtime_overlay
assert 'CMD ["gateway", "run"]' not in overlay
assert 'if [ "$RUNTIME_PERSONA" = "roy" ]' in overlay
assert "HERMES_KANBAN_" not in roy_supervisor
assert "[program:roy-gateway]" in roy_supervisor
for persona in ("denholm", "richmond", "the-elders"):
    dockerfile_text = (root / f"ops/images/Dockerfile.{persona}").read_text(encoding="utf-8")
    assert 'CMD ["gateway", "run"]' in dockerfile_text
assert "command:\n    - gateway\n    - run" not in compose
assert "image: ${MOSS_IMAGE_REF:?" in compose
assert "additional_contexts:" not in compose
assert "MOSS_BASE_IMAGE:" not in compose
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
assert 'if [[ -z "${MOSS_IMAGE_REF:-}" ]]; then' in smoke
assert 'started=true\n"${compose[@]}" up -d moss' in smoke
assert 'curl -fsS http://127.0.0.1:8787/health' in smoke
assert 'curl -fsS http://127.0.0.1:8648/health' in smoke
assert 'curl -fsS http://127.0.0.1:8644/health' not in smoke
assert 'persisted routes and their' in smoke
assert 'http://127.0.0.1:9119/' not in smoke
print("moss-candidate-build-contract: PASS")
