# Moss Hermes tools

Installed in the image:

- git / gh
- jq / ripgrep / sqlite3
- Python 3 + venv
- curl / DNS tools / ping / netcat
- openssh-client / rsync

Not mounted by default in production MVP:

- Docker socket
- private-host SSH private keys
- OpenClaw credentials

Those mounts would make the dashboard a high-impact control surface and should be added only after an explicit security review.
