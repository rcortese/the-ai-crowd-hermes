# Compose environment style and offline validation

## Separate public and private models

`compose.yaml` is a portable example, not an operational fleet export. Its
JSON-subset syntax needs only Python's standard library. Each service uses an
alphabetical `environment` mapping with explicit string values. `AGENT_NAME`,
`HERMES_HOME` and `TERMINAL_CWD` are retained integration contracts; absence of a
literal reader in one source snapshot does not prove obsolescence. The reviewed
bindings and persona-specific required image/mount interpolation gates live in
`ops/policies/compose-environment.json`.

Run `python3 tests/lint_compose_env.py` for the public scaffold. It does not read
`.env`, start Hermes, render Compose, contact Docker, or access the network. A
new environment name or env_file is not silently admitted: review its consumer,
security scope and delivery contract separately.

Operational configurations belong in a private isolated candidate, never in
this public repository. The generic tooling below handles YAML there without
requiring that an actual deployment use the scaffold's three-name contract.
Only synthetic fixtures and generic tooling belong in the public source.

## Operational workflow (source-only)

Use a validation interpreter with reviewed PyYAML (tested with PyYAML 6.0.3).
Do not install into or edit an agent's runtime/profile to run the lint. The
public scaffold lint remains standard-library-only. The default offline suite
keeps that boundary. To additionally run operational YAML tests, explicitly set
`COMPOSE_ENV_PYTHON` to an existing isolated validation interpreter; absence of
that option emits `operational_yaml_tests_not_requested`, not an operational
acceptance result.

Capture an exact private baseline and its SHA-256, source checkout/HEAD, and
preexisting dirty state. Capture names only from its ordered env_file inputs;
never put their secret values into source, logs or a public artifact. Write and
review a private catalog as described below. Then, using private local paths:

```sh
python tests/normalize_compose_env.py --baseline BASELINE --output NEW_CANDIDATE
python tests/lint_compose_env.py --scope operational --compose NEW_CANDIDATE \
  --baseline BASELINE --contract PRIVATE_CATALOG
```

The normalizer exclusively creates a private-mode file; it never overwrites an
existing file or follows an output symlink. It expands legacy inheritance,
converts explicit numeric baseline environment scalars to their strings, sorts
service environment keys and emits JSON-subset YAML. Comments and anchor syntax
are not retained. It rejects ambiguous baseline passthrough/null/boolean values
and duplicate keys before overwrite. The baseline may contain intentional YAML
merge inheritance; the candidate may not contain merges or aliases. The lint
compares the entire parsed models after baseline environment normalization,
including non-environment fields, exact interpolation expressions, empty values,
ordered env_file paths, gates, mounts and other service configuration. This is
structural source equivalence, not execution/render parity or a YAML schema
certification for every Compose feature. Ambiguous YAML implicit types require
explicit baseline review; do not silently coerce them.

No lint success authorizes deployment or publication. Before later integration,
reconcile the exact baseline against current source drift; never replace a dirty
operational checkout with the public example. The normalizer can produce a file
that needs further review: only the paired lint and the reviewed catalog form
the acceptance check. Unknown/uncertain bindings are retained, not removed.

## Private catalog schema

A catalog has `version: 1`, `services` and `env_files` mappings. Each service
records `environment` (each name has `status: keep` or `uncertain`, plus a
nonempty `consumer` evidence/reason), the exact ordered `env_file` list, and
`overrides`, an exact list of names duplicated across layers. `env_files` maps
each referenced path to a name-to-metadata mapping with `status` and `consumer`
for each file-only name as well, never values. A missing manifest
fails closed. This manifest is evidence captured separately, not proof that
files still exist or their contents remain unchanged; revalidate names against
actual files privately at the execution gate. No env_file value is loaded by
the lint. An explicitly reviewed empty `environment` override remains an
override, not a missing value. Dynamic `*_API_KEY_ENV` identifiers must refer to
a name delivered by environment or inventoried env_file. References are not
credentials; SHA-256 integrity identifiers and session key prefixes are not
classified as credential literals. Sensitive-key literal values and nonempty
secret defaults are rejected. Diagnostics omit operational names, values,
private paths and parser excerpts. The rule is a naming-based safety check,
not a comprehensive secret scanner or authorization to publish private inputs.

## Three phases of precedence

Compose interpolation is a host-side phase. Shell values take precedence over
interpolation files; explicit ordered `--env-file` inputs replace default `.env`
discovery, with later files winning. Fix the project directory and input files
explicitly for any separately authorized render. `.env` does not automatically
become container environment. `${VAR:-x}` uses the fallback for unset or empty;
`${VAR-x}` uses it only for unset; `${VAR:?message}` requires nonempty; `$$`
escapes Compose interpolation. The lint preserves these literal expressions;
it does not reimplement Compose interpolation.

Container startup is another phase: an applicable explicit `compose run -e`
override wins; service `environment` wins over `env_file` even when explicitly
empty; later env_files override earlier ones; image ENV is fallback. Entrypoints
and supervisors may make additional changes.

Application/profile loading is a third phase. A process/profile `.env` loader
may use override semantics; do not claim Compose invariably wins or that Docker
Config.Env is the effective application environment. Keep deployment/persona
selectors and credential edits in the deployment-owned root inputs, rather than
introducing a second hidden editable credential copy in profile homes. Before
any process test, prove the test home contains no production credentials (or
uses only test credentials); disabling integrations alone is insufficient.
These tools perform only offline source checks and never load profile homes.

References: [Docker interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/),
[Docker container precedence](https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/),
[Hermes configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration).

## Regression checks

`./tests/run-all.sh` when `COMPOSE_ENV_PYTHON` is set, also runs positive and causal negative operational CLI fixtures: duplicate
keys, merges/aliases, types, passthrough, ordering, missing/new names, changed
bindings/default operators/required gates, env_file order and inventory,
reviewed layered overrides including empty, dynamic proxy targets, integrity
digests, malformed YAML and diagnostic redaction. It also runs the existing
privacy, scaffold, retention and persona contract checks. All tests are offline.
Keep exact baseline/candidate digests, interpreter version, commands, test
results and no-lifecycle evidence in the private handoff. Never log raw rendered
configuration or `docker compose config --environment` from a real deployment.
