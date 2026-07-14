# Moss multi-root write-safe-root operation

## Contract
`HERMES_WRITE_SAFE_ROOT` is a path-separator-delimited allowlist. Empty/unset
means no additional allowlist. A nonempty value that resolves to no valid roots
fails closed with `HERMES_WRITE_SAFE_ROOT has no valid roots`. Exact credential
and system paths, protected directory prefixes, and active/global Hermes
`mcp-tokens` and `pairing` directories always win over an allowlist.

Diagnostics are deliberately limited to normalized configured paths: protected
paths report `protected system/credential file`; allowlist misses report
`outside HERMES_WRITE_SAFE_ROOT (...)`.

## Fleet build gate
Every persona Dockerfile copies and executes
`ops/images/write-safe-root-contract.py`; run
`ops/tests/test_fleet_write_safe_root_build_contract.sh` before any candidate
build. The gate is source-backed by
`ops/hermes-agent-overrides/write-safe-root-invalid-config-fail-closed.patch`.
Source-backed base images install `patch` before the patch/gate layer so the
pinned base image's package set cannot bypass or prevent this contract.

## Candidate runner and rollback boundary
Run `ops/scripts/deploy-moss-write-safe-root-candidate.sh --help` first. With
no `--execute`, every phase is inert: it performs no Git/Docker call and writes
no state. Executed phases record commit-addressed evidence under
`ops/candidates/write-safe-root-<full-commit>/`; the requested commit must
resolve exactly to the checkout `HEAD` before the runner creates that state or
touches Docker.

`preflight`, `build`, and `validate` are ordered read/build/inspect phases;
none can stop or recreate a service. Candidate build makes a temporary Docker
context exclusively with `git archive` of the resolved full commit, verifies its
file tree against that commit, then directly builds `Dockerfile.moss` to a
commit-scoped temporary base tag and `Dockerfile.moss-all-in-one` with
`MOSS_BASE_IMAGE` bound to that tag. The temporary context and base tag are
removed on both success and failure. Build and validation never invoke Compose or read an environment file. Preflight uses only read-only inspection: it binds the canonical container target (default `the-ai-crowd-moss-1`, never bare `moss`) plus checkout HEAD, SHA-256 of the staged binary diff, target container ID and immutable image ID, rendered Compose SHA-256, and—when the candidate exists—the immutable candidate image ID. `promote` requires same-commit validation and this activation evidence, recomputes every bound fact immediately before its first mutation, and fails closed before any lifecycle command on a mismatch or missing target. It tags the candidate into the compose image reference, recreates only the configured Moss compose service, and validates the same canonical container using the candidate image. Any failure after the stop (including signals) retags and recreates from the exact CAS-bound old image, then validates that same canonical container before reporting the original failure. Validation preserves the candidate tag and image for K7 review/activation; only explicit `abort` closeout may remove them. A successful promotion keeps durable phase evidence but removes the temporary rollback-image marker.

K3/K4/K5 must not execute a build, candidate, or promotion. K6 owns isolated
candidate build/validation. K7 approval plus an external guarded invocation is
required before the runner may touch only Moss.
