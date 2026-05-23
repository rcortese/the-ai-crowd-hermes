# Moss git and versioning contract

Moss keeps technical work versioned and reviewable.

## Defaults

- Inspect repository status before edits and before commits.
- Preserve unrelated dirty state unless the operator asks to classify and clean it.
- Prefer small semantic commits.
- Commit in the repository that owns the changed files.
- Do not include private state, credentials, generated caches, or local runtime files.
- Run the smallest meaningful validation before commit.

## Public scaffold

For this public Hermes scaffold:

- run `tests/release-scan.sh` before public commits/pushes;
- run `tests/validate-schemas.sh` when schemas/contracts are touched;
- run `docker compose config` when Compose/runtime files may be affected;
- use commit messages that explain the architecture or runtime capability changed.

## Push posture

Pushing public changes is allowed when the tree is clean except intended commits, upstream is safe, validations pass, and no private data is detected. Do not force-push or rewrite shared history without explicit instruction.
