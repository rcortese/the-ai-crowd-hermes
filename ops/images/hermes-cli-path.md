# Hermes CLI in login-shell PATH

## Problem

The image exports `/opt/hermes/.venv/bin` in `ENV PATH`, but `/etc/profile` replaces `PATH` when the terminal backend starts a login shell. As a result, the absolute executable `/opt/hermes/.venv/bin/hermes` works while `hermes` is not found.

## Durable fix

`Dockerfile.moss-all-in-one` creates `/usr/local/bin/hermes` as a symlink to `/opt/hermes/.venv/bin/hermes`. `/usr/local/bin` remains in the login-shell PATH. The build fails closed if that path already contains a regular file or a symlink to another target.

The authenticated Honcho package image inherits the all-in-one base and only overlays/compiles application files, so the link is retained by that final image. A normal image rebuild and deployment are still required before the fix survives container recreation.

## Live activation

For the current container, create the same link as root only after verifying that the target is executable and `/usr/local/bin/hermes` is absent. This needs no restart or recreate. Before removing it, verify the exact target so rollback never deletes an unrelated command.

## Verification

Run as the runtime UID/GID (`99:100`):

    /bin/sh -lc 'command -v hermes && hermes --version'
    /bin/bash -lc 'command -v hermes && hermes --version'
    env -i HOME=/opt/data HERMES_HOME=/opt/data PATH=/usr/local/bin:/usr/bin:/bin /bin/sh -c 'command -v hermes && hermes --version'
    env -i HOME=/opt/data HERMES_HOME=/opt/data PATH=/usr/local/bin:/usr/bin:/bin /bin/bash -c 'command -v hermes && hermes --version'

Also verify that the container ID and image ID did not change during activation. These checks do not call a model or modify Hermes profiles, credentials, memory, gateway state, or lifecycle.

## Rollback

Live container: while the same container ID remains active, remove `/usr/local/bin/hermes` only if it is still a symlink whose literal target is `/opt/hermes/.venv/bin/hermes`.

Source: revert the commit before the next image build if the behavior is no longer wanted. Never remove the venv executable.
