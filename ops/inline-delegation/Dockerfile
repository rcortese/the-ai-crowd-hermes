# build.sh verifies this local tag resolves to the exact active image ID.
FROM moss-terminal-aggregate:release-959381e4d17344398665f44b8e6407d7
USER root
COPY apply.py /usr/local/share/moss-inline-delegation/apply.py
RUN /opt/hermes/.venv/bin/python3 /usr/local/share/moss-inline-delegation/apply.py \
    && /opt/hermes/.venv/bin/python3 -m py_compile \
       /opt/hermes/gateway/platforms/api_server_openai_routes.py \
       /opt/hermes/gateway/platforms/api_server_runs.py \
       /opt/hermes-webui/api/gateway_chat.py \
    && printf '%s  %s\n' \
       af84277268986a36db192e70c716645ec2c4a1e28f32f000657ecf4055c4ba84 /opt/hermes/gateway/platforms/api_server_openai_routes.py \
       1b406016503f4cded06e081c154379d5af0903fb699a0d2ad20096b54f5ac1a8 /opt/hermes/gateway/platforms/api_server_runs.py \
       73094c5a27be52718d966aa0aa62e34d81d55f716853718ea66b3eb35ddfccc3 /opt/hermes-webui/api/gateway_chat.py \
       | sha256sum -c - \
    && chmod 0644 /usr/local/share/moss-inline-delegation/apply.py
LABEL the-ai-crowd.inline-delegation="http-inline-on-webui" \
      the-ai-crowd.inline-delegation.agent-source="7cfcce43d80ee913c0c007a86ef3c9383c0b90b0" \
      the-ai-crowd.inline-delegation.webui-source="f40a6a8674d2842a0be7bdb7b65e963d2af71bc4"
