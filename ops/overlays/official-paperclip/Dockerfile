# Recipe only: no build/deployment has been executed for this candidate.
# Build context is the root of the-ai-crowd-hermes. Both arguments are required.
ARG HERMES_BASE_IMAGE
FROM ${HERMES_BASE_IMAGE}
USER root
ARG HERMES_METADATA_VARIANT
COPY ops/overlays/official-paperclip /opt/build-overlays/official-paperclip
RUN /opt/hermes/.venv/bin/python /opt/build-overlays/official-paperclip/apply.py \
      --target /opt/hermes --variant "${HERMES_METADATA_VARIANT}"
