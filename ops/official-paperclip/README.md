# Official Paperclip components — candidate build delivery

This directory owns only reproducible build recipes, locks and technical receipts.
It does **not** activate a runtime, change Compose/config, migrate a database,
restart/recreate/reload a service, mutate the board, or push Git/images.
Independent review and production acceptance belong to the integrating parent.

## Inputs and artifact boundaries

- `source.json` pins Paperclip commit/tree, upstream base, adapter pre/post hashes
  and the five authorized existing image bases. This is a local downstream
  candidate, **not a claim that these changes shipped upstream**.
- MCP source package is `@paperclipai/mcp-server@0.1.0`; the historical installed
  registry version `2026.1012.0` is a different distribution, not this source.
- `build-deps/` is the npm-ci-locked compiler/test environment (including the
  original repository acpx patch). Builds export Git objects, not dirty source.
- `runtime-package-lock.json` locks the production dependency graph. The two
  workspace packages are deterministic local distribution tarballs: shared
  `0.3.1` and MCP `0.1.0`. Only their publish metadata is materialized; MCP's
  `workspace:*` dependency is resolved to the exact co-built shared version.
  Official JS/TS component code is not wrapped, bridged or replaced.
- The output `paperclip-mcp.tar.gz` is a closed production npm tree, including
  both local tarballs and the production lock. It has only internal relative
  symlinks, no compiler/test dependency tree and no scratch-path dependency.
  **Node itself is inherited from the immutable persona base**, not bundled;
  minimum Node is 24.11.0. Exercised builder: Node 26.7.0, npm 12.0.2, Python 3.14.
- The output `execute.ts` is the exact official-candidate source blob, installed
  natively at `/app/packages/adapters/hermes/src/gateway/server/execute.ts`.
  The server imports TS exports through its existing `tsx`; there is no server
  rebuild, dependency update, DB access, migration or alternate adapter.
- Nothing generated (`node_modules`, dist, tar, images) belongs in Git.

## Reproduce from a committed recipe

Export this directory from the reviewed delivery commit into a fresh directory
under the active profile's `$TMPDIR` (never a live source/home). Run the exported
scripts, not a dirty checkout. The Paperclip repository needs the exact pinned
commit object; its current worktree bytes are not consumed.

```sh
mkdir "$TMPDIR/official-recipe"
git archive DELIVERY_COMMIT ops/official-paperclip | tar -x -C "$TMPDIR/official-recipe"
RECIPE="$TMPDIR/official-recipe/ops/official-paperclip"
python3 "$RECIPE/test_delivery.py"
python3 "$RECIPE/build_components.py" \
  --paperclip /path/to/authorized/paperclip-repository \
  --out "$TMPDIR/official-components"
python3 "$RECIPE/smoke_mcp.py" \
  "$TMPDIR/official-components/paperclip-mcp/node_modules/.bin/paperclip-mcp-server"
```

The component builder runs `npm ci --ignore-scripts`, compiles shared,
adapter-utils, Hermes adapter and MCP, runs all adapter tests and the MCP run
context/origin tests, then runs `npm ci --omit=dev --ignore-scripts` and published
export imports. Public npm network access is needed for a fresh dependency cache;
no credentials are consumed. The packaged runtime needs no installation/network.
`npm ls` reports the SDK's optional `@cfworker/json-schema` peer as absent; all
required dependencies resolve, and the stdio/catalog/call path is exercised.

To intentionally refresh the runtime lock, use `--resolve-runtime-lock` with a
new scratch output and review/copy its generated package lock into this directory
under separate edit authority. This resolution output is explicitly
`lockedRelease: false` and the image builder rejects it. Normal release builds
always consume the versioned lock via npm ci, never resolve it afresh.

## Isolated local images

The Docker endpoint must be explicit. For the current authorized MEDIA daemon:

```sh
python3 "$RECIPE/build_image.py" --docker-host ssh://media \
  --components "$TMPDIR/official-components" --role moss \
  --tag the-ai-crowd/moss-official-mcp:tac246-UNIQUE \
  --out "$TMPDIR/official-image-moss"
```

Repeat with `--role denholm`, `jen`, `richmond`, and `adapter`, distinct tags and
output directories. MCP roles select their pinned persona bases. `--base` may
select a separately authorized immutable MCP-layer base; adapter only accepts
its pinned server base. Immutable image IDs or repository@sha256 digests are
required. Existing candidate tags are refused, not repointed. Tag names are
restricted to a `tac246-` suffix; choose a new unique value per attempt.

`Dockerfile.mcp` copies the production tree to `/opt/paperclip-mcp`; the future
configuration executable is:

```
/opt/paperclip-mcp/node_modules/.bin/paperclip-mcp-server
```

Persona config/activation and the independent Hermes Python forward-port are
not part of this layer. The older home-mounted MCP stays untouched/inactive only
when the parent later changes configuration. These Node-only images do not
contain that Python forward-port and are not final integrated fleet images.

`Dockerfile.adapter` permits precisely one source target, checks its known
preimage before COPY and its postimage afterward, restores USER node, and
imports the module through `tsx` from `/app/server`, where tsx is actually
installed. Both overlays preserve the base entrypoint, command, environment,
working directory and user; the builder verifies these and the base-layer prefix.
Inherited OCI source/revision labels describe the base, not this new layer;
separate `ing.paperclip.*.source` labels describe the overlay.

Builds use `--pull=false --network=none`. Smoke containers are disposable,
read-only, network-none, capability-free, have PID/CPU/memory limits and do not
mount home, Docker socket, secrets, source or host state, nor publish ports.
MCP runs as 99:100 and gets only a synthetic credential and loopback HTTP fixture.
The fixture proves 44 catalog tools, missing/invalid-context fail-closed before
HTTP, independent successive run headers, no sticky fallback, path-origin
rejection, and redirect rejection. All fixture writes are in-memory HTTP only.
It requires a clean EOF exit and no MCP stderr. Server smoke imports native TS
only; no service entrypoint runs. The daemon's exact known warning that swap
limits are unavailable is recorded, not confused with MCP stderr; all other
unexpected smoke stderr fails the builder.

## Observed results and limitations

`delivery-manifest.json` binds the already exercised artifacts/image IDs and
receipt locations. Resolution and locked rebuild produced byte-identical MCP
tars. Source tests: 20 MCP tests (17 context + 3 origin), 115 adapter tests.
Delivery custody tests: 9 passing (including bad locks/hashes/bases, existing tag,
archive determinism and symlink escape checks). Four isolated image MCP smokes
passed with 44 tools each; native adapter import passed in its candidate image.

Early attempts exposed and corrected test/build-envelope issues: the URL error
oracle must inspect official formatted JSON errors (REST errors do not use MCP
`isError`); `tsx` resolves from `/app/server`, not `/app`; Docker endpoint must
be explicit rather than relying on shell export persistence. The first Moss
image completed but receipt generation rejected the known Docker swap warning;
its successful later receipt binds that same image ID. The failed adapter build
left no successfully tagged `...20261015a` adapter image. Early logs remain in
scratch as diagnostic history, not success receipts.

No independent final review, authenticated real heartbeat/end-to-end Hermes
acceptance, production configuration or activation was performed here. Tests
use synthetic runs **only inside an isolated loopback fixture**, never the board.
Read-only production identity checks before/after matched container ID, image,
StartedAt and restart count for all four personas and the Paperclip server.
