#!/usr/bin/env bash
# Source contract: every rendered Hermes persona must map to a Dockerfile that
# copies and *executes* the shared runtime gate during its build.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 - "$repo_root" <<'PY'
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
contract = "ops/images/write-safe-root-contract.py"
expected_service_dockerfiles = {
    "moss": "ops/images/Dockerfile.moss-all-in-one",
    "jen": "ops/images/Dockerfile.jen",
    "denholm": "ops/images/Dockerfile.denholm",
    "roy": "ops/images/Dockerfile.roy-all-in-one",
    "richmond": "ops/images/Dockerfile.richmond",
    "the-elders": "ops/images/Dockerfile.the-elders",
}
all_persona_dockerfiles = {
    "ops/images/Dockerfile.moss",
    "ops/images/Dockerfile.moss-all-in-one",
    "ops/images/Dockerfile.jen",
    "ops/images/Dockerfile.denholm",
    "ops/images/Dockerfile.richmond",
    "ops/images/Dockerfile.roy",
    "ops/images/Dockerfile.roy-all-in-one",
    "ops/images/Dockerfile.the-elders",
}
required_base_persona_dockerfiles = {
    "ops/images/Dockerfile.moss",
    "ops/images/Dockerfile.jen",
    "ops/images/Dockerfile.denholm",
    "ops/images/Dockerfile.richmond",
    "ops/images/Dockerfile.roy",
    "ops/images/Dockerfile.the-elders",
}
interpreter = "/opt/hermes/.venv/bin/python3"


def persona_services(services):
    """Detect persona services from rendered build and image properties, not names."""
    detected = {}
    for name, service in services.items():
        build = service.get("build") or {}
        dockerfile = build.get("dockerfile")
        image = service.get("image")
        image_indicator = isinstance(image, str) and image.startswith("the-ai-crowd/")
        dockerfile_indicator = (
            isinstance(dockerfile, str)
            and dockerfile.startswith("ops/images/Dockerfile.")
        )
        if image_indicator or dockerfile_indicator:
            detected[name] = service
    return detected


def has_contract_copy(source):
    return any(
        re.match(r"(?i)^\s*(?:COPY|ADD)\s+", line)
        and contract in line
        for line in source.splitlines()
    )


def has_patch_prerequisite(source):
    gate = source.find("RUN command -v patch")
    if gate < 0:
        return True
    install = source.find("apt-get install -y --no-install-recommends patch")
    return 0 <= install < gate


def has_contract_execution(source):
    # Fold Dockerfile line continuations, then parse each shell command segment.
    # A copied path, comment, or echo argument cannot make the interpreter argv[0].
    folded = re.sub(r"\\\n", " ", source)
    for line in folded.splitlines():
        match = re.match(r"(?i)^\s*RUN\s+(.*)$", line)
        if not match:
            continue
        for segment in re.split(r"(?:&&|\|\||;)", match.group(1)):
            try:
                tokens = shlex.split(segment, comments=True)
            except ValueError:
                continue
            if tokens and tokens[0] == interpreter and any(
                token.endswith("write-safe-root-contract.py") for token in tokens[1:]
            ):
                return True
    return False


def verify_persona_services(services, dockerfile_sources, expected_map):
    detected = persona_services(services)
    unknown = sorted(set(detected) - set(expected_map))
    if unknown:
        raise ValueError(f"detected persona services absent from gate map: {unknown}")
    missing = sorted(set(expected_map) - set(detected))
    if missing:
        raise ValueError(f"expected persona services absent from rendered config: {missing}")

    for service, dockerfile in expected_map.items():
        build = detected[service].get("build") or {}
        if build.get("dockerfile") != dockerfile:
            raise ValueError(
                f"service {service!r} is not mapped to its expected Dockerfile: "
                f"got={build.get('dockerfile')!r}, expected={dockerfile!r}"
            )
        source = dockerfile_sources[dockerfile]
        if not has_contract_copy(source):
            raise ValueError(f"missing common write-safe-root contract copy: {dockerfile}")
        if not has_contract_execution(source):
            raise ValueError(f"missing executable write-safe-root contract gate: {dockerfile}")
        if not has_patch_prerequisite(source):
            raise ValueError(f"missing patch prerequisite before source-backed gate: {dockerfile}")


def assert_rejected(name, services, sources, expected_map):
    try:
        verify_persona_services(services, sources, expected_map)
    except ValueError:
        return
    raise SystemExit(f"mutation fixture unexpectedly passed: {name}")


def verify_patch_prerequisites(dockerfile_sources, required_dockerfiles):
    for dockerfile in required_dockerfiles:
        if not has_patch_prerequisite(dockerfile_sources[dockerfile]):
            raise ValueError(f"missing patch prerequisite before source-backed gate: {dockerfile}")


def assert_patch_prerequisite_rejected(name, dockerfile_sources, required_dockerfiles):
    try:
        verify_patch_prerequisites(dockerfile_sources, required_dockerfiles)
    except ValueError:
        return
    raise SystemExit(f"mutation fixture unexpectedly passed: {name}")


# Mutation coverage keeps the checker honest before it is applied to the fleet.
fixture_map = {"known": "ops/images/Dockerfile.known"}
known_service = {
    "image": "the-ai-crowd/known:local",
    "build": {"dockerfile": "ops/images/Dockerfile.known"},
}
real_gate = f"COPY {contract} /opt/hermes/write-safe-root-contract.py\nRUN {interpreter} /opt/hermes/write-safe-root-contract.py\n"
assert_rejected(
    "unknown persona service",
    {"known": known_service, "ghost": {"image": "the-ai-crowd/ghost:local", "build": {"dockerfile": "ops/images/Dockerfile.ghost"}}},
    {"ops/images/Dockerfile.known": real_gate},
    fixture_map,
)
assert_rejected(
    "image-only unknown persona service",
    {
        "known": known_service,
        "unknown-image-only": {
            "image": "the-ai-crowd/ghost:local",
            "build": {"dockerfile": "third-party/Dockerfile.ghost"},
        },
    },
    {"ops/images/Dockerfile.known": real_gate},
    fixture_map,
)
assert_rejected(
    "Dockerfile-only unknown persona service",
    {
        "known": known_service,
        "unknown-dockerfile-only": {
            "image": "third-party/ghost:local",
            "build": {"dockerfile": "ops/images/Dockerfile.ghost"},
        },
    },
    {"ops/images/Dockerfile.known": real_gate},
    fixture_map,
)
assert_rejected(
    "COPY-only Dockerfile",
    {"known": known_service},
    {"ops/images/Dockerfile.known": f"COPY {contract} /opt/hermes/write-safe-root-contract.py\n"},
    fixture_map,
)
assert_rejected(
    "comment-only RUN",
    {"known": known_service},
    {"ops/images/Dockerfile.known": f"COPY {contract} /opt/hermes/write-safe-root-contract.py\n# RUN {interpreter} /opt/hermes/write-safe-root-contract.py\n"},
    fixture_map,
)
assert_rejected(
    "echo-only RUN",
    {"known": known_service},
    {"ops/images/Dockerfile.known": f"COPY {contract} /opt/hermes/write-safe-root-contract.py\nRUN echo '{interpreter} /opt/hermes/write-safe-root-contract.py'\n"},
    fixture_map,
)
try:
    verify_persona_services({"known": known_service}, {"ops/images/Dockerfile.known": real_gate}, fixture_map)
except ValueError as exc:
    raise SystemExit(f"actual interpreter mutation fixture unexpectedly failed: {exc}")

# Worktrees intentionally exclude the credential-bearing fleet env file. An
# empty ephemeral fixture is sufficient for interpolation and is removed before
# this contract exits; no runtime credentials are read or created.
env_fixtures = (repo / "env" / "fleet.env", repo / "env" / "roy.env")
created_env_fixtures = []
for env_file in env_fixtures:
    if not env_file.exists():
        env_file.parent.mkdir(parents=True, exist_ok=True)
        env_file.write_text("")
        created_env_fixtures.append(env_file)
try:
    rendered = subprocess.run(
        ["docker", "compose", "config", "--format", "json"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
finally:
    for env_file in created_env_fixtures:
        env_file.unlink()
    if created_env_fixtures:
        try:
            created_env_fixtures[0].parent.rmdir()
        except OSError:
            pass
if rendered.returncode:
    raise SystemExit(f"docker compose config failed:\n{rendered.stderr}")
services = json.loads(rendered.stdout)["services"]
dockerfile_sources = {}
for dockerfile in all_persona_dockerfiles:
    path = repo / dockerfile
    if not path.is_file():
        raise SystemExit(f"missing persona Dockerfile: {dockerfile}")
    dockerfile_sources[dockerfile] = path.read_text()

verify_patch_prerequisites(dockerfile_sources, required_base_persona_dockerfiles)
for dockerfile in sorted(required_base_persona_dockerfiles):
    mutated_sources = dict(dockerfile_sources)
    mutated_sources[dockerfile] = mutated_sources[dockerfile].replace(
        "apt-get install -y --no-install-recommends patch",
        "apt-get install -y --no-install-recommends not-patch",
        1,
    )
    assert_patch_prerequisite_rejected(
        f"patch prerequisite missing: {dockerfile}",
        mutated_sources,
        required_base_persona_dockerfiles,
    )

try:
    verify_persona_services(services, dockerfile_sources, expected_service_dockerfiles)
except ValueError as exc:
    raise SystemExit(str(exc))
PY
