# Agent container model — example

The public model separates Moss, Jen, Denholm, Roy, Richmond and The Elders into service examples. Their roles do not imply any running service or active channel.

The example mounts each public persona contract read-only at `/contracts`, an operator-selected private workspace at `/workspace` and a separate runtime home at `/runtime`. Image and source directories are mandatory variables. An installation may adapt these targets through reviewed private configuration; the scaffold does not mandate an image-specific entrypoint, user identity or healthcheck.

Public source lives under `agents/public/<agent>/`. Private workspaces and runtime caches, credentials, sessions and memories must not be tracked or archived for public distribution. Public contracts are not another persona's private source authority.

The default example has one internal network, no published ports, no external networks and no shared auth mount. Shared files, if authorized separately, are passive artifacts rather than interpersona request transport. Native A2A requires its own authenticated private configuration; no edge is activated here.

Host control, writable project mounts, provider access and external delivery each require explicit reviewed private capabilities. Validate the scaffold offline; validate the actual runtime separately.
