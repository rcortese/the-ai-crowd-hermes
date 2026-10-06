# Offline validation and publication

From the repository root, run `./tests/run-all.sh`. Requirements are Python 3 standard library, Git and Bash. The final success marker is `offline_suite_ok`.

The suite exercises synthetic Git repositories (including branch-only and tag-only histories), archive parity, redacted privacy diagnostics, portable retention engine behavior, public scaffold structure and Moss contract smoke checks. Fixture repositories are disposable and never modify this repository's refs. No Docker, network or provider calls are made.

## Mandatory publication gate

```bash
python3 tests/privacy_guard.py --mode all
```

The default inspects the working tree, `git archive HEAD` against every tracked tree entry and blob, and all objects reachable from every local head/tag. Historical commit/tag messages, ref names, deleted/renamed blobs, protected runtime paths and gitlinks are included. `export-ignore` and `export-subst` cannot bypass parity. No host-path allowlist exists.

The gate emits JSON with `ok`, counts and findings; exit 0 means clean and exit 1 means blocked or inspection failure. Diagnostics contain only surfaces, detector labels and SHA-256 locator prefixes. Investigate matched bytes privately. This is a pattern-based project gate, not a proof of absence of every possible secret.

`--mode tree` checks pending edits and untracked nonignored files. Ignored local runtime state is not a publication candidate. `--mode archive --revision <commit>` checks an immutable distribution. `--mode history` checks local heads/tags, not remote refs, hosting caches, forks or backups. Ensure the intended publication refs have been fetched into the audit repository before relying on coverage.

An uncommitted candidate may pass the offline suite while committed archive/history fail. Do not interpret that as publication approval. History repair and pushing require explicit separate authorization; this gate never rewrites refs or pushes.

## Compose

Offline tests validate the example source and all required variable names without contacting Docker. A separate optional Compose render can be performed in an authorized environment after supplying every variable from `.env.example`; no render or container runtime is required for the offline suite. Runtime images, identity, startup behavior, credentials and healthchecks are intentionally deployment-owned and not certified here.
