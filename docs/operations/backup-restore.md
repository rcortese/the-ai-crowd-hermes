# Backup and restore runbook

Status: Public contract
Owner: Moss

This runbook defines what must be backed up before Hermes Moss can be treated as production-ready. It intentionally avoids private paths, hostnames, credentials, and backup destinations.

## Backup classes

| Class | Public repo handling | Private handling |
|---|---|---|
| Public scaffold | Git remote and release tags | Re-clone by commit SHA |
| Agent homes | Public examples only | Back up deployment `agents/*` state |
| Moss private repo | Ignored nested repo | Back up/commit curated private state |
| Credentials/OAuth/provider state | Never versioned | Secret manager or encrypted backup |
| Runtime sessions/cache/logs | Never public | Back up only if intentionally retained |
| Project mounts | Not part of scaffold | Each project follows its own backup policy |

## Minimum backup evidence

Private deployment notes should record public-safe references:

- `public_commit`: commit SHA deployed;
- `base_image`: digest from `ops/manifests/base-images.lock.json`;
- `private_state_ref`: opaque `private-ref:*` pointer to backup evidence;
- `agent_home_backup_ref`: opaque `private-ref:*` pointer;
- `restore_rehearsal_ref`: opaque `private-ref:*` pointer or blocked reason;
- `rollback_ref`: `file:docs/ROLLBACK.md` or private deployment rollback note.

Do not publish real backup paths, hostnames, bucket names, credentials, or operator contact details.

## Restore rehearsal

A restore rehearsal should prove that a new checkout can be assembled from:

1. public repo at the target commit;
2. private deployment override files;
3. private `agents/*` state backup;
4. nested Moss private repo backup;
5. credentials rehydrated through approved private handling;
6. validation commands.

Public-safe rehearsal command shape:

```bash
git clone <public-repo> <restore-checkout>
cd <restore-checkout>
git checkout <commit-sha>
# restore private state from private-ref:* using private deployment procedure
./tests/run-all.sh
./tests/smoke-deploy.sh
```

`smoke-deploy` must run only where Docker access is authorized.

## Rollback

Rollback without data deletion:

1. Remove or disable private routing to the Hermes dashboard.
2. Stop Moss with Compose if needed.
3. Revert public repo to the last known good commit.
4. Restore private state only if the release changed private data.
5. Run validation before re-enabling routing.

Never delete live agent homes as the first rollback step. Move or snapshot them first unless the operator explicitly authorizes destructive cleanup.
