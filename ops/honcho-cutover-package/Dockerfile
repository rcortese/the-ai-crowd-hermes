ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 0:0
COPY overlay/ /opt/hermes/
COPY webui/ /opt/hermes-webui/
COPY . /opt/moss-honcho-package/
RUN /opt/hermes/.venv/bin/python -m compileall -q /opt/hermes/agent/moss_memory_gate.py /opt/hermes/plugins/memory/honcho /opt/hermes/gateway/platforms/api_server.py /opt/hermes-webui/api/gateway_chat.py /opt/hermes-webui/api/routes.py
