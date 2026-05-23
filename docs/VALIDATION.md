# Validation checks

## Public-safe validation entrypoint

From the repository root:

```bash
./tests/run-all.sh
```

Expected final line:

```text
run_all_ok
```

The entrypoint runs:

- Moss contract smoke validation;
- wrapper preflight template smoke validation;
- workspace dirty-watch read-only wrapper validation;
- image pin validation;
- health check validation;
- drift detection validation;
- schema/example validation;
- release scan;
- private-state ignore policy validation;
- mount-policy scan over rendered Compose;
- history scan over current HEAD and reachable commits;
- `git diff --check`;
- base Compose config rendering;
- project-mount example Compose rendering with a placeholder project root.

These checks are intended to be public-safe and non-privileged. They do not start containers or mutate Docker state.

## Individual checks

```bash
./agents/public/moss/tests/contract-smoke-test.sh
./agents/public/moss/tools/wrappers/preflight-template.sh --capability project_files --target example-project
./agents/public/moss/tools/wrappers/workspace-dirty-watch.sh --repo . --label hermes-public-scaffold
./agents/public/moss/tools/wrappers/messaging-dry-run.sh --channel direct-message --recipient private-ref:operator-direct --message 'public scaffold dry run' --dry-run
./agents/public/moss/tools/wrappers/ssh-readonly-preflight.sh --host-ref private-ref:private-infra-host --user-ref private-ref:private-infra-user --command-class host-summary --dry-run
./agents/public/moss/tools/wrappers/compose-readonly-preflight.sh --repo . --mode config --dry-run
./tests/image-pin.sh
./tests/health-check.sh
./tests/drift-detection.sh
./tests/validate-schemas.sh
./tests/release-scan.sh
./tests/private-state-policy.sh
./tests/private-mount-boundary.sh
./tests/cutover-policy.sh
./tests/capability-lanes.sh
./tests/mount-policy.sh
./tests/history-scan.sh
git diff --check
docker compose -f compose.yaml config >/dev/null
HERMES_EXAMPLE_PROJECTS_ROOT=/PUBLIC_PLACEHOLDER/projects \
  docker compose -f compose.yaml -f compose.project-mount.example.yaml config >/dev/null
```

Expected outputs include:

- `moss_contract_smoke_ok`
- `preflight_template_ok=true`
- `workspace_dirty_watch_ok=true`
- `image_pin_ok`
- `health_check_ok`
- `drift_detection_ok`
- `schema_validation_ok`
- `release_scan_ok`
- `private_state_policy_ok`
- `private_mount_boundary_ok`
- `cutover_policy_ok`
- `capability_lanes_ok`
- `base_mount_policy_ok`
- `project_example_mount_policy_ok`
- `history_scan_ok`

## Release and history scan policy

The public scaffold must not contain:

- tracked private state files such as environment files, runtime configs, auth state, logs, sessions, or checkpoints;
- credentials, tokens, OAuth state, or private keys;
- literal deployment hostnames, private network addresses, private filesystem paths, or private storage roots;
- public default Docker socket mounts, broad host mounts, or other host-control authority;
- private reverse-proxy source-of-truth names or live route files.

The scans use generic pattern classes rather than storing real private markers in the public repo.

## Runtime smoke tests

Run only in an environment where Docker daemon access is authorized:

```bash
./tests/smoke-deploy.sh
```

Expected outcomes:

- `smoke_deploy_ok` and exit `0` when Compose builds/starts Moss and the dashboard responds inside the container.
- `smoke_deploy_blocked: ...` and exit `2` when Docker CLI or daemon access is unavailable.
- Nonzero failure when build/start/readiness fails.

The smoke script uses a temporary Compose project and cleans up containers it starts.

## Private endpoint auth smoke test

If a private reverse proxy is configured, verify from the intended private network that:

- the configured external proxy Docker network exists before deployment;
- the reverse-proxy container is attached to that same network;
- the agent container is attached to both the internal project network and the configured proxy network after deployment;
- the stable alias `hermes` resolves from the reverse-proxy container;
- `http://hermes:9119/` is reachable from the reverse-proxy container;
- unauthenticated requests are blocked where the private proxy policy requires it;
- authenticated or otherwise authorized requests reach the Hermes dashboard;
- requests from unintended networks are blocked;
- the public Compose file still has no host `ports:` binding;
- canonical deploy commands use only `compose.yaml`.

Keep private hostnames, paths, routes, and credentials in private deployment notes, not in this repository.
