# Private mount boundary

Status: public scaffold contract

Hermes separates each agent into three filesystem planes:

```text
agents/public/<agent>/   # tracked public contract
agents/private/<agent>/  # ignored private workspace
runtime/<agent>-home/    # ignored runtime home/state
```

Inside an agent container, those planes are consumed as:

```text
/agents/<agent>/public   # read-only public contract
/agents/<agent>/private  # read-write private workspace
/opt/data                # read-write runtime home
/mnt/hermes-shared       # shared handoff area
```

## Rule

Mount the public contract and private workspace separately. Do not mount the repository root or the whole `agents/` tree into a normal agent container.

Accepted pattern for Moss:

```text
./runtime/moss-home:/opt/data
./agents/public/moss:/agents/moss/public:ro
./agents/private/moss:/agents/moss/private:rw
./state/shared:/mnt/hermes-shared
```

Repeat the same pattern for other agents by replacing the slug.

## Retired risk patterns

Do not use these as active runtime mounts:

```text
.:/workspace/the-ai-crowd:ro
./agents:/agents:ro
./agents/moss:/opt/data
```

Broad mounts are unsafe because tooling may treat a path as public-safe while ignored private/runtime files are also visible below it.

## Validation expectation

Public scaffold tests should verify:

1. `agents/private/` is ignored and untracked.
2. Public mounts target `/agents/<agent>/public` and are read-only.
3. Private mounts target `/agents/<agent>/private` and are read-write.
4. Runtime writes go to `/opt/data`, not to the public contract.
5. Retired broad/root mounts are absent.

Private deployments may add sentinel tests to prove private data is not reachable through public paths.
