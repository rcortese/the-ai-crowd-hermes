# Moss inline HTTP delegation: canonical-source release candidate

Moss-only source lineage: agent `7cfcce43d80e`, WebUI `f40a6a8674d2`.
The older running image is extended with three preimage-hash-bound edits. WebUI
requests inline delegation over Chat Completions and Runs API; non-WebUI
clients keep their existing behavior. The built candidate image is
`sha256:14a0a1930c386a9342efae4db712d3dcd39a9c4298709dcc3e0b39863a612f30`.

Canonical release: the source branch pins this image in `compose.yaml`.
The existing `projects` writable bind in source remains; deployment will
converge to EIGHT mounts, not silently remove that source contract. The old
running container has seven mounts. No other persona image selection is
changed in the source commit.

The private host package lives at
`/mnt/ssd/appdata/the-ai-crowd/staging/inline-delegation-f842332`.
`release.json` binds the final source commit and `release.bundle` SHA-256.
The host source checkout is at `de1afd1` with a dirty Compose file: one line
pins Moss to the active old image, another unrelated service image is locally
updated. `source_transition.py` checks exact preimages, stages new source
files from the bundle, preserves that unrelated image line, advances the
host branch by CAS, and retains a private Compose/index backup and receipt.
No reset, clean, stash, or ordinary merge over the dirty host checkout.

After Rodolfo's explicit OK only: from SSH on the Docker HOST run
`bash <host package>/launch.sh approved-launch`; never use `docker exec`.
The host `setsid`/`nohup` supervisor records its PID before the initiating
Moss container is replaced. The worker prepares the source transaction,
renders the canonical Compose, runs `docker compose -f compose.yaml up -d
--no-deps --no-build moss` (NO image/mount overlay for activation), checks
health, all eight mounts and endpoints, then fast-forwards remote `main` and
reads it back. The host checkout keeps the other service's local image edit.
`ACTIVE_HEALTHY` is infrastructure health, not proof of functional
delegation; Rodolfo will verify an actual WebUI turn afterward.

Before remote publication, failures attempt recovery of Moss to the previous
image with seven mounts, then restore the exact prior host Compose/index and
Git ref. A missing container, unknown image, lost remote visibility, or
interruption after remote publication is RECOVERY_REQUIRED, not permission
for a blind ref rewind. `rollback.sh approved-rollback` is ONLY for recovery
of an interrupted, unpublished cutover. Do not use it after success:
post-publication reversal requires a NEW, versioned revert commit and a
separately reconciled runtime change, never force-push/rewrite main.

The package alone is not activation. At each stage inspect `launcher.state`,
`activation.state`, `source-receipt.json`, host Git HEAD/dirty status,
remote main, container image/mounts/health, and the service endpoints. A
host power loss still needs manual reconciliation against these receipts.
