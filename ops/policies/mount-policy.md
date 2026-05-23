# Mount policy

Mounts are authority boundaries. Adding a mount can grant access even when no new binary or credential is added.

## Default posture

Default public Compose files must not mount:

- Docker socket;
- SSH key material;
- broad host roots such as `/`, `/home`, or private host storage roots;
- provider or messaging credentials;
- real private project paths;
- secret directories except placeholder `ops/secrets/.gitkeep`.

## Mount classes

| Class | Default | Review required | Notes |
|---|---:|---:|---|
| Public source | read-only | no | public scaffold inspection |
| Agent home | read-write | no | per-agent runtime state |
| Shared handoff | scoped | yes for writers | no secrets by default |
| Project mount | opt-in | yes | explicit project and access mode |
| Private repo | opt-in | yes | private deployment state |
| SSH material | absent | yes | wrapper-only after review |
| Docker control | absent | yes | prefer remote wrapper over socket |
| Host path | absent | yes | narrow path only |

## Rules

- Prefer read-only mounts until write access is required.
- Use named, narrow mount targets.
- Use placeholders in public examples.
- Keep real paths in private overlays.
- Document purpose, owner, mode, preflight, and validation for each new mount.
- Never add broad host mounts to public defaults.

## Validation

Run `tests/mount-policy.sh` after changing Compose or mount examples.
