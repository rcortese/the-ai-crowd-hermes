ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 0:0
ARG AGENT_COMMIT
ARG WEBUI_COMMIT=none
ARG AGENT_ARCHIVE
ARG WEBUI_ARCHIVE
COPY ${AGENT_ARCHIVE} /tmp/agent.tar
COPY ${WEBUI_ARCHIVE} /tmp/webui.tar
COPY old-agent-files.json install-source.py /tmp/
RUN /opt/hermes/.venv/bin/python /tmp/install-source.py "${AGENT_COMMIT}" "${WEBUI_COMMIT}" \
 && rm /tmp/agent.tar /tmp/webui.tar /tmp/install-source.py /tmp/old-agent-files.json
WORKDIR /opt/hermes
# Keep persona-specific extras installed; all core versions come from the release lock.
RUN test -x /usr/bin/python3.13 \
 && uv sync --python /usr/bin/python3.13 --no-managed-python --frozen --inexact --no-dev --extra all --extra messaging --extra otlp --extra anthropic --extra bedrock --extra azure-identity \
 && uv pip install --python /opt/hermes/.venv/bin/python --no-deps -e . \
 && /opt/hermes/.venv/bin/hermes --version \
 && /opt/hermes/.venv/bin/python -c 'import sys,sqlite3; assert sys.version_info[:2] == (3,13); assert sqlite3.sqlite_version_info >= (3,53,4); print(sys.version, sqlite3.sqlite_version)'
ARG RUNTIME_WORKDIR
RUN ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci --workspace web --workspace ui-tui --include-workspace-root --no-audit --fetch-retries=3 \
 && npm run build --workspace web \
 && npm run build --workspace ui-tui
RUN if [ "${WEBUI_COMMIT}" != none ]; then \
      uv pip install --python /opt/hermes/.venv/bin/python -r /opt/hermes-webui/requirements.txt; \
    fi \
 && chown -R 99:100 /opt/hermes \
 && if [ "${WEBUI_COMMIT}" != none ]; then chown -R 99:100 /opt/hermes-webui; fi \
 && test "$(id -u hermes)" = 99 && test "$(id -g hermes)" = 100
RUN chmod 0755 /opt/hermes/docker/entrypoint-dispatch.sh
RUN if [ "${RUNTIME_WORKDIR}" = /agents/moss/private ]; then \
      if [ -L /usr/local/bin/hermes ]; then \
        test "$(readlink /usr/local/bin/hermes)" = /opt/hermes/.venv/bin/hermes; \
      else test ! -e /usr/local/bin/hermes && ln -s /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes; fi; \
    fi
WORKDIR ${RUNTIME_WORKDIR}
ARG AGENT_TREE
ARG WEBUI_TREE=none
ARG DERIVED_BASE
LABEL the-ai-crowd.agent-source-tree="${AGENT_TREE}" \
      the-ai-crowd.webui-source-tree="${WEBUI_TREE}" \
      the-ai-crowd.hermes-base-id="${DERIVED_BASE}" \
      the-ai-crowd.hermes-base-source-revision="inherited-see-derived-base" \
      the-ai-crowd.hermes-base-source-tree="inherited-see-derived-base" \
      the-ai-crowd.derived-base="${DERIVED_BASE}" \
      the-ai-crowd.agent-source-commit="${AGENT_COMMIT}" \
      the-ai-crowd.webui-source-commit="${WEBUI_COMMIT}" \
      the-ai-crowd.release="20260922-agent-0.21.4-webui-0.52.113"
