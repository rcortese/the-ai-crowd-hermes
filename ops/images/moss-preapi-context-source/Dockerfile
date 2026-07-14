FROM the-ai-crowd/moss-all-in-one:rollback-before-webui-api-intermediate-prod-20260701T044611Z
COPY background_process.py /opt/hermes-webui/api/background_process.py
COPY apply_context_meter.py /tmp/apply_context_meter.py
RUN python3 /tmp/apply_context_meter.py \
 && rm /tmp/apply_context_meter.py
ENV HERMES_WEBUI_CHAT_BACKEND=legacy-direct
