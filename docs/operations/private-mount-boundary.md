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
/mnt/hermes-shared       # passive referenced artifacts; not interpersona transport
```

## Rule

Mount the public contract and private workspace separately. Do not mount the repository root or the whole `agents/` tree into a normal agent container.

Accepted pattern for a regular agent (Jen, Denholm, Richmond, The Elders):

```text
./runtime/<agent>-home:/opt/data
./agents/public/<agent>:/agents/<agent>/public:ro
./agents/private/<agent>:/agents/<agent>/private:rw
./state/shared:/mnt/hermes-shared
```

Moss runs from an immutable runtime snapshot instead. The public contract and the
private source are both mounted read-only from `runtime/moss-*-<release>`; only
`projects/` is writable:

```text
./runtime/moss-home-<release>:/opt/data
./runtime/moss-public-<release>:/agents/moss/public:ro
./runtime/moss-source-<release>:/agents/moss/private:ro
./runtime/moss-source-<release>/projects:/agents/moss/private/projects   # rw
./state/shared:/mnt/hermes-shared
```

`<release>` is `MOSS_RUNTIME_RELEASE` in `compose.yaml`.

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
