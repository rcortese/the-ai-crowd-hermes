# The AI Crowd Hermes

Public distribution scaffold for specialized assistants on Hermes Agent. It is not an installed fleet, a private source authority, or a ready-to-deploy image release.

| Assistant | Role |
|---|---|
| Moss | Technical operations, infrastructure, runtime and incidents |
| Jen | Productivity, tasks and calendar |
| Denholm | Product stewardship and cross-agent coherence |
| Roy | Direct personal assistance for the configured operator |
| Richmond | Archive stewardship |
| The Elders | Answers from approved, restricted packets |

## Contents and boundaries

- `agents/public/`: persona contracts, portable tools and examples.
- `schemas/` and `examples/`: public data contracts and synthetic examples.
- `ops/manifests/` and `ops/policies/`: capability and access examples.
- `ops/runtime-backup-retention.py`: portable manifest-based retention engine; no installer, host target or automatic activation.
- `compose.yaml`: deployment-agnostic example with explicit image and mount variables.
- `tests/`: offline source tests and publication gates.

Private deployment runners, provider configuration, build closures, fleet image locks and operational incident records are not distributed here. Credentials, memories, logs, sessions and runtime state must stay outside public Git. Public contracts grant no access to another persona's private sources.

## Offline validation

Requirements: Python 3 standard library, Git and Bash. No Docker, provider credentials, image pulls or network access.

```bash
./tests/run-all.sh
```

This checks the candidate working tree and runs synthetic Git/history/archive tests, portable engine tests and source contracts. It does **not** certify existing committed history or a deployment. The separate mandatory publication gate inspects the committed archive and every object reachable from all local heads and tags:

```bash
python3 tests/privacy_guard.py --mode all
```

Use `--mode tree`, `--mode archive --revision HEAD`, or `--mode history` for diagnostics. Findings contain rule labels and hashed locators, never matching source text. An uncommitted repair can pass tree tests while archive/history still fail; publication remains blocked until the authorized history repair is verified. Export attributes cannot hide tracked files from the archive parity check. Gitlinks and protected runtime roots are rejected.

## Compose example

The public Compose example uses the JSON subset of YAML so its syntax and source policy can be validated with the Python standard library, without a YAML package or Docker. `.env.example` lists every required image and mount variable. Its image names are intentionally non-runnable placeholders. Supply reviewed, compatible images and existing private directories locally; the scaffold neither builds nor downloads them. Each service receives `/runtime`, `/workspace` and read-only `/contracts`. Image entrypoints, user identity, secrets, channel configuration, healthchecks and access routing belong to your reviewed private deployment configuration.

The example has one internal network, no published ports, no external network, no Docker socket and no broad host mounts. Configure authorized egress explicitly if your runtime needs it. `compose.project-mount.example.yaml` adds only a read-only synthetic project mount. A Compose render requires all base variables even when validating this overlay. No command in the offline suite contacts a Docker daemon.

## Documentation

Start with [the documentation index](docs/README.md) and persona contracts under `agents/public/`. Architecture and operational guides are examples, not assertions of live access or current production state. Native A2A is a product transport option; no remote edge or credential is activated by this repository.

Publication is source-only and distinct from deployment. History verification covers local heads/tags, not hosting-service pull-request caches, forks, backups or other copies; passing does not imply universal erasure.
