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

## Candidate runner and rollback boundary
Run `ops/scripts/deploy-moss-write-safe-root-candidate.sh --help` first. The
runner is dry-run unless `--execute` is given and has explicit phases. K3/K4/K5
must not execute a build, candidate, or promotion. K6 owns isolated candidate
build/validation. K7 approval plus an external guarded invocation is required
before the runner may touch only Moss; any post-stop failure must restore the
recorded exact image before reporting failure.
