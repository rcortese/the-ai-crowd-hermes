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
removed on both success and failure. These three phases never invoke Compose or
read an environment file. `promote` requires the same-commit `validate`
evidence and is the only phase which can recreate `moss`. It first records the
running Moss image ID, tags the candidate into the compose image reference,
stops only `moss`, recreates only `moss`, and validates a healthy container
using the candidate image. Any failure after the stop (including signals)
retags and recreates from that exact recorded image, then validates the rollback
image before reporting the original failure. A successful promotion keeps
durable phase evidence but removes the temporary rollback-image marker.

K3/K4/K5 must not execute a build, candidate, or promotion. K6 owns isolated
candidate build/validation. K7 approval plus an external guarded invocation is
required before the runner may touch only Moss.
