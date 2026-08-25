#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail(){ echo "native_a2a_cutover_failed: $1" >&2; exit 1; }
compose=compose.yaml
moss="$(awk '''$0=="  moss:"{h=1;next} h&&/^  [A-Za-z0-9_-]+:$/{exit}h{print}''' "$compose")"
denholm="$(awk '''$0=="  denholm:"{h=1;next} h&&/^  [A-Za-z0-9_-]+:$/{exit}h{print}''' "$compose")"
printf '%s
' "$moss" | grep -Fq 'MOSS_TO_DENHOLM_A2A_TOKEN:' || fail 'Moss lacks A2A caller credential reference'
printf '%s
' "$denholm" | grep -Fq 'A2A_PEER_TOKENS: moss:${MOSS_TO_DENHOLM_A2A_TOKEN' || fail 'Denholm lacks Moss peer token reference'
printf '%s
' "$denholm" | grep -Fq 'A2A_TRUSTED_PEERS: moss' || fail 'Denholm does not bind Moss identity'
printf '%s
' "$denholm" | grep -Fq "    - '9900'" || fail 'Denholm lacks internal A2A port'
if grep -Eq 'PERSONA_(CALLER|TARGET)_' "$compose"; then fail 'legacy persona API credentials remain in compose'; fi
if grep -Eq 'persona_rpc|persona-rpc' README.md agents/public/moss/config.example.yaml agents/public/richmond/config.example.yaml agents/public/the-elders/config.example.yaml; then fail 'legacy RPC remains in active config/docs'; fi
printf '%s
' native_a2a_cutover_ok
