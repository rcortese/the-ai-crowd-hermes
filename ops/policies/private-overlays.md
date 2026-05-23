# Private overlays

Private overlays are deployment-specific Compose or config files that add local authority without committing private state to the public scaffold.

## Public examples

Public examples may show shape only, using placeholders such as:

- `${HERMES_EXAMPLE_PROJECTS_ROOT}`
- `example-project`
- `/workspace/projects/example-project`
- `PRIVATE_NETWORK_NAME`

## Private files

Private deployments may create ignored files such as:

- `compose.private.yaml`
- private `.env` files;
- private agent `config.yaml`;
- private nested repos.

## Rules

- Keep real paths, hostnames, credentials, and network names out of public git.
- Validate private overlays with `docker compose ... config` before use.
- Add review gates before enabling SSH, Docker control, provider credentials, or messaging.
- Prefer wrappers and preflight checks over direct raw host authority.
