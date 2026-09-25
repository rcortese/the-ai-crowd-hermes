ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN /opt/hermes/.venv/bin/python3 -c "import hashlib,pathlib; p=pathlib.Path('/opt/hermes/tools/terminal_tool.py'); assert hashlib.sha256(p.read_bytes()).hexdigest() == 'f75f50fc916cd19331a3bc55044a1096f9a287e6782cb8effb32dc5fc57f3c5b'"
COPY terminal.patch /opt/hermes/terminal-readonly-approval.patch
RUN git -C /opt/hermes apply --check /opt/hermes/terminal-readonly-approval.patch && git -C /opt/hermes apply /opt/hermes/terminal-readonly-approval.patch && chown 99:100 /opt/hermes/tools/terminal_tool.py && /opt/hermes/.venv/bin/python3 -c "import hashlib,pathlib; p=pathlib.Path('/opt/hermes/tools/terminal_tool.py'); assert hashlib.sha256(p.read_bytes()).hexdigest() == '43f16c2ebbdf7c2524cb91ac7e95fcab37ad3458e68929213fd1248ad38c1c6f'"
LABEL the-ai-crowd.terminal-fix-commit="2a3de9bd2944c06542592d5031d706afb279abb1"
