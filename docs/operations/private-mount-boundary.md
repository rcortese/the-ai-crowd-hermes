# Private mount boundary — example

Separate public contracts, private workspaces and runtime state. The public `compose.yaml` illustrates `/contracts` (read-only), `/workspace` (private writable) and `/runtime` (private writable) for each service. Images must be configured to consume those mount targets; existing installations may use other paths.

Public contracts live under `agents/public/<agent>/`. Actual workspace and runtime source directories are explicit operator-supplied variables, not tracked public files. `agents/private/`, `private/`, runtime state, auth, logs and sessions must never be published. A local ignore rule is not a substitute for checking tracked files and Git history.

Do not mount the repository root, the whole agent tree, a host filesystem root, credentials or a Docker socket by default. Do not give one persona another persona's private workspace. Existing bind source directories are required; the example does not create them automatically.

`compose.project-mount.example.yaml` demonstrates a single read-only project mount. Writable projects, shared passive artifacts and host-control capabilities require independent private authorization and review. Nothing in this scaffold activates a capability.

Validate with `./tests/run-all.sh` and the separate committed publication gate documented in [validation](../VALIDATION.md). Private deployments may add sentinel tests without publishing sensitive values.
