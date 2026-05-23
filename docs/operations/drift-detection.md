# Drift detection

Status: Public contract
Owner: Moss

Drift detection keeps the public scaffold, private deployment, and running containers from silently diverging.

## Public-safe drift checks

The public scaffold provides `tests/drift-detection.sh`. It verifies:

- the checkout is a Git worktree;
- public Git does not track `agents/moss/private/`;
- ignored private runtime state is not accidentally prepared as public content;
- `agents/moss/private/` remains a nested Git repo if present;
- the nested private repo has no remote during scaffold hardening.

Run through:

```bash
./tests/drift-detection.sh
```

or the full validation entrypoint:

```bash
./tests/run-all.sh
```

## Private deployment drift checks

Private deployment notes should add environment-specific checks without publishing private values:

- deployed public commit equals intended `origin/main` commit;
- base image digest equals `ops/manifests/base-images.lock.json` or an approved override;
- private Compose override has no unexpected host ports;
- private routing still enforces authentication and intended network boundaries;
- private agent homes are backed up according to the backup policy;
- no unreviewed SSH/Docker/provider/channel mounts were added;
- running container health matches Compose state.

## Drift response

If drift is found:

1. Classify it as public scaffold drift, private deployment drift, private state drift, or runtime container drift.
2. Stop before mutating live routing or credentials.
3. Preserve evidence using public-safe summaries or `private-ref:*`.
4. Reconcile through the release process.
5. Rerun validation and smoke tests appropriate to the affected layer.

Do not normalize undocumented private changes by copying them into the public repo. Public changes need review and release evidence; private changes need private deployment notes and backup evidence.
