# env/

Secret-bearing stack env files.

- `.env` in the stack root is the human-edited environment contract and Compose interpolation source.
- `env/fleet.env` is the only active `env_file` injected into persona containers.
- Do not put persona/channel credentials in `env/fleet.env`; use persona-prefixed slots in root `.env`.
- Development slots stay empty unless a dev-owned credential exists.
