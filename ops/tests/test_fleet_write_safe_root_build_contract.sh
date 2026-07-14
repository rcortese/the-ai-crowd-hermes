#!/usr/bin/env bash
# Source contract: every rendered Hermes persona must map to a Dockerfile that
# copies and *executes* the shared runtime gate during its build.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec python3 - "$repo_root" <<'PY'
import hashlib
import json
import posixpath
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


moss_build_manifests = {
    "ops/images/moss-clash-royale-war-bot/package.json": "c94203f97cc6977afea4f5248f0f337f3dd1642ab7b4333b8307858435cff1db",
    "ops/images/moss-clash-royale-war-bot/package-lock.json": "00619e87bd755ebccd3b93f7c1e73a470d90ddf98827b8681210706b27935d01",
}
expected_playwright = {"range": "^1.59.1", "version": "1.59.1", "integrity": "sha512-C8oWjPR3F81yljW9o5OxcWzfh6avkVwDD2VYdwIGqTkl+OGFISgypqzfu7dOe4QNLL2aqcWBmI3PMtLIK233lw=="}
secret_pattern = re.compile(r"AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")

def docker_copy_sources(source):
    sources = []
    folded = re.sub(r"\\[ \t]*\r?\n", " ", source)
    for line in folded.splitlines():
        if line.lstrip().startswith("#"):
            continue
        match = re.match(r"(?i)^\s*(COPY|ADD)\s+(.+)$", line)
        if not match:
            continue
        arguments = match.group(2).strip()
        payload = re.sub(r"^(?:(?:--[A-Za-z0-9][A-Za-z0-9_-]*(?:=[^\s]*)?)\s+)+", "", arguments)
        try:
            tokens = json.loads(payload) if payload.startswith("[") else shlex.split(payload, comments=False)
        except (ValueError, json.JSONDecodeError):
            raise ValueError(f"unparseable {match.group(1).upper()} instruction: {line}")
        if not isinstance(tokens, list) or not all(isinstance(token, str) for token in tokens):
            raise ValueError(f"invalid operands in {match.group(1).upper()} instruction: {line}")
        if len(tokens) < 2:
            raise ValueError(f"missing source or destination in {match.group(1).upper()} instruction: {line}")
        sources.extend(posixpath.normpath(token) for token in tokens[:-1])
    return sources

def verify_no_private_overlay_copy(source):
    private_sources = [path for path in docker_copy_sources(source) if path.lstrip("/") == "agents/private" or path.lstrip("/").startswith("agents/private/")]
    if private_sources:
        raise ValueError(f"Dockerfile COPY/ADD must not source ignored agents/private: {private_sources}")

def assert_private_overlay_copy_rejected(name, source):
    try:
        verify_no_private_overlay_copy(source)
    except ValueError:
        return
    raise SystemExit(f"private-overlay mutation fixture unexpectedly passed: {name}")

def verify_moss_build_manifests(repo):
    if not all((repo / path).is_file() for path in moss_build_manifests):
        raise ValueError("missing tracked Moss Playwright build manifest")
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", *moss_build_manifests], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if tracked.returncode:
        raise ValueError(f"Moss Playwright build manifest is not tracked: {tracked.stderr.strip()}")
    for relative_path, expected_hash in moss_build_manifests.items():
        payload = (repo / relative_path).read_bytes()
        if hashlib.sha256(payload).hexdigest() != expected_hash:
            raise ValueError(f"unexpected build manifest hash: {relative_path}")
        decoded = payload.decode("utf-8")
        if secret_pattern.search(decoded) or re.search(r"https?://[^/@\s]+:[^/@\s]+@", decoded):
            raise ValueError(f"secret-like content in tracked build manifest: {relative_path}")
    package = json.loads((repo / "ops/images/moss-clash-royale-war-bot/package.json").read_text())
    lock = json.loads((repo / "ops/images/moss-clash-royale-war-bot/package-lock.json").read_text())
    if package.get("dependencies", {}).get("playwright") != expected_playwright["range"] or lock.get("lockfileVersion") != 3:
        raise ValueError("unexpected Moss Playwright manifest dependency or lockfile version")
    root_dependencies = lock.get("packages", {}).get("", {}).get("dependencies", {})
    playwright = lock.get("packages", {}).get("node_modules/playwright", {})
    if root_dependencies.get("playwright") != expected_playwright["range"]:
        raise ValueError("package-lock root Playwright dependency does not match package.json")
    if playwright.get("version") != expected_playwright["version"] or playwright.get("integrity") != expected_playwright["integrity"]:
        raise ValueError("unexpected locked Playwright package integrity")


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


# Mutation coverage keeps the private-overlay source guard honest.
assert_private_overlay_copy_rejected("continued COPY from ignored private overlay", "COPY ./agents/private/moss/projects/clash-royale-war-bot/package.json \\\n agents/private/moss/projects/clash-royale-war-bot/package-lock.json \\\n /opt/clash-royale-war-bot-node/\\n")
assert_private_overlay_copy_rejected("ADD from ignored private overlay", "ADD agents/private/moss/projects/clash-royale-war-bot/package.json /opt/clash-royale-war-bot-node/\\n")
assert_private_overlay_copy_rejected("flagged JSON COPY from ignored private overlay", "COPY --link=true [\"agents/private/x\", \"/dst\"]\n")
assert_private_overlay_copy_rejected("flagged JSON ADD from ignored private overlay", "ADD --chmod=0644 [\"./agents/private/x\", \"/dst\"]\n")

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

verify_moss_build_manifests(repo)
for dockerfile, source in dockerfile_sources.items():
    verify_no_private_overlay_copy(source)

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
