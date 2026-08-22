#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
dockerfile = (root / "ops/images/Dockerfile.moss-all-in-one").read_text(encoding="utf-8")
helper = (root / "ops/scripts/build-moss-all-in-one-candidate.sh").read_text(encoding="utf-8")
roy_supervisor = (root / "ops/images/roy-all-in-one.supervisor.conf").read_text(encoding="utf-8")
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
assert 'BASE_IMAGE="${MOSS_BASE_IMAGE:-}"' in helper
assert 'MOSS_BASE_IMAGE must be an immutable local sha256 image ID' in helper
assert 'base_alias="the-ai-crowd/moss-build-base:${BASE_IMAGE#sha256:}"' in helper
assert '--build-arg "MOSS_BASE_IMAGE=$base_alias"' in helper
assert "git -C \"$ROOT\" archive --format=tar \"$COMMIT\"" in helper
assert "sha256sum -c \"$CTX/$MANIFEST_REL\"" in helper
assert 'org.opencontainers.image.revision=' in helper
assert 'org.opencontainers.image.source=' in helper
for path in ('ops/scripts/build-a2a-moss-denholm-candidate.sh', 'ops/scripts/build-persona-base-candidate.sh'):
    builder = (root / path).read_text(encoding='utf-8')
    assert 'org.opencontainers.image.revision=' in builder
    assert 'org.opencontainers.image.source=' in builder
assert "--build-context \"clash_royale_build_input=$INPUT_DIR\"" in helper
for legacy_path in (
    'ops/images/Dockerfile.moss-a2a-overlay',
    'ops/images/Dockerfile.runtime-a2a-overlay',
    'ops/scripts/build-moss-a2a-overlay-candidate.sh',
    'ops/scripts/build-runtime-a2a-overlay-candidate.sh',
    'ops/scripts/materialize-persona-toolset-runtime.py',
):
    assert not (root / legacy_path).exists()
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
assert "networks: !reset [smoke]" in smoke
assert "env_file: !reset []" in smoke
assert "volumes: !override" in smoke
assert "API_SERVER_KEY: moss-smoke-isolated-api-key" in smoke
assert "smoke_deploy_failed: isolated API key missing" in smoke
assert "TELEGRAM_BOT_TOKEN: ''" in smoke
assert '"${compose[@]}" down --remove-orphans --volumes' in smoke
assert 'export MOSS_IMAGE_REF="$MOSS_SMOKE_IMAGE_ID"' in smoke
assert 'curl -fsS http://127.0.0.1:8787/health' in smoke
assert 'curl -fsS http://127.0.0.1:8648/health' in smoke
assert 'curl -fsS http://127.0.0.1:8644/health' not in smoke
print("moss-candidate-build-contract: PASS")
