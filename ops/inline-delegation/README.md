# Moss WebUI HTTP delegation: prepared host-only cutover

Scope: Moss all-in-one container only. Chat Completions and Runs API accept the
per-request `X-Hermes-Delegate-Mode: inline` header; the Moss WebUI sends it on
both paths. Other HTTP clients retain existing detached delegation semantics.
No session store, credential, Telegram, or other persona changes.

Source lineage: agent `7cfcce43d80ee913c0c007a86ef3c9383c0b90b0`, WebUI
`f40a6a8674d2842a0be7bdb7b65e963d2af71bc4`. These full candidate
files are NOT copied into the older running image. `apply.py` applies only the
three semantic edits to SHA-bound installed files. `build.sh` guards the local
base image ID, builds `local/moss-inline-delegation:prepared-v1`, then tests
hashes and imports in a disposable container with networking disabled.

Host package: `/mnt/ssd/appdata/the-ai-crowd/staging/inline-delegation-f842332`.
Preflight: `python3 <host package>/preflight.py`. It must report READY against
the currently active image, healthy container, Compose input hash, matching
mount projection, and prepared candidate. Stop on ANY drift. The host's
Compose service currently differs from the running container: it adds a
`projects` bind. `compose.override.yaml` uses Compose `!override` to preserve
exactly the seven current mounts. Do not use plain `docker compose up moss`.

After Rodolfo's explicit OK only: via SSH on the Docker host, execute
`bash <host package>/launch.sh approved-launch`. Never run it through
`docker exec`: the replacement terminates the initiating Moss process.
The host launcher checks the preflight, starts a `setsid`/`nohup` supervisor
outside the container, and writes `launcher.pid` and `launcher.state` to
persistent host storage. Inspect the host PID and receipt after the request
ends. The supervisor runs the worker with a timeout and reconciles its exit;
the worker takes a host flock, repeats preflight before Compose, runs a
service-only no-build up, waits for Docker health and three endpoints, and
attempts service-only rollback on failure. The supervisor retries rollback
when an interrupted worker left the candidate present. A killed host or
missing/unknown container needs operator reconciliation; no automatic host
reboot recovery is claimed. Read both states, supervisor process exit, new
container ID/image, and actual health before claiming activation. An
`ACTIVE_HEALTHY` receipt proves service health, NOT functional delegation:
Rodolfo's practical WebUI turn will validate that separately.

Manual reversal after a healthy cutover: on the Docker host run
`bash <host package>/rollback.sh approved-rollback`. It requires the expected
Compose hash and the candidate image currently active. Wait for
`ROLLED_BACK_HEALTHY` in `activation.state` and confirm old image and health.
This is a narrowly scoped runtime exception; the host Compose's main image
field remains on the old image. Before a later unrelated Compose rollout,
merge the approved image into the versioned deployment source or roll back:
otherwise a plain Compose up can undo this fix. A successful host cutover is
not a full fleet-source promotion.

Current status: image built, offline import and hash checks green, host
preflight green; activation and real human turn NOT run. No automation
should infer deployment from the presence of these files or the image tag.
