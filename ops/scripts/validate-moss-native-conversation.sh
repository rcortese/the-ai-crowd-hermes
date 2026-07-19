#!/usr/bin/env bash
# Fake-first native conversation gate; caller supplies only the literal container name.
set -Eeuo pipefail
[[ ${HDDT_REHEARSAL:-0} == 1 ]] || { printf '%s\n' 'disposable rehearsal required' >&2; exit 77; }
[[ ${1:-} == --container && ${2:-} == the-ai-crowd-moss-1 && $# == 2 ]] || exit 64
db=${HDDT_DOCKER_BIN:?}; http=${HDDT_HTTP_BIN:?}; expected=${HDDT_CANDIDATE_IMAGE_ID:?}; network=${HDDT_EXPECTED_NETWORK:?}; cookie=${HDDT_COOKIE_JAR:?}; sse=${HDDT_SSE_FILE:?}
meta=$("$db" inspect "$2")
jq -e --arg image "$expected" --arg net "$network" '.Image==$image and .State.Running==true and .State.Health.Status=="healthy" and .Config.Labels["com.docker.compose.project"]=="the-ai-crowd" and .Config.Labels["com.docker.compose.service"]=="moss" and (.NetworkSettings.Networks[$net].IPAddress|test("^[0-9]+(\\.[0-9]+){3}$"))' <<<"$meta" >/dev/null || exit 78
ip=$(jq -r --arg net "$network" '.NetworkSettings.Networks[$net].IPAddress' <<<"$meta"); [[ $ip != 127.* ]] || exit 78
base="http://$ip:8787"; profile=moss; workspace=moss-native-workspace; marker=moss-native-marker; session=; stream=; succeeded=0
cleanup(){ local response rc
  [[ -n $session ]] || return 0
  "$http" POST "$base/api/session/delete" "{\"session_id\":\"$session\"}" "$cookie" | jq -e --arg s "$session" '.ok==true and .session_id==$s' >/dev/null || return 1
  for delay in 0 2 4 6; do
    response= rc=0; response=$("$http" GET "$base/api/session?session_id=$session&messages=0&poll=$delay" '' "$cookie") || rc=$?
    ((rc==22)) && jq -e --arg s "$session" '.status==404 and .error=="Session not found" and .session_id==$s' <<<"$response" >/dev/null || return 1
    "$http" GET "$base/api/chat/stream/status?stream_id=$stream" '' "$cookie" | jq -e --arg s "$stream" '.stream_id==$s and .active==false' >/dev/null || return 1
  done
}
on_exit(){ rc=$?; trap - EXIT INT TERM; cleanup || { printf '%s\n' 'native cleanup failed' >&2; ((rc==0)) && rc=79; }; ((rc==0 && succeeded==1)) && printf '%s\n' 'NATIVE_CONVERSATION=PASS CLEANUP=PASS'; exit "$rc"; }
trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
"$http" POST "$base/api/profile/switch" '{"name":"moss"}' "$cookie" | jq -e '.active==true and .name=="moss" and .cookie==true' >/dev/null
"$http" GET "$base/api/profile/active" '' "$cookie" | jq -e '.name=="moss"' >/dev/null
session=$("$http" POST "$base/api/session/new" "{\"profile\":\"$profile\",\"workspace\":\"$workspace\"}" "$cookie" | jq -er '.session.session_id|strings')
start=$("$http" POST "$base/api/chat/start" "{\"session_id\":\"$session\",\"profile\":\"$profile\",\"workspace\":\"$workspace\",\"message\":\"$marker\"}" "$cookie")
stream=$(jq -er --arg s "$session" '.stream | select(.session_id==$s) | .stream_id | strings' <<<"$start")
"$http" GET "$base/api/chat/stream?session_id=$session&stream_id=$stream" '' "$cookie" SSE >"$sse"
[[ $(grep -Fc '[DONE]' "$sse" || true) == 0 ]] || exit 79
awk '/^data: /{sub(/^data: /,"");print}' "$sse" | jq -s -e --arg s "$session" --arg t "$stream" --arg m "$marker" '
  all(.[]; type=="object" and (has("error")|not) and (has("app_error")|not) and (has("cancel")|not))
  and ([.[]|select(.event=="token" or .event=="message")|.text]|join("")|contains($m))
  and ([.[]|select(.event=="done")]|length)==1
  and ([.[]|select(.event=="done")][0].session.session_id)==$s
  and ([.[]|select(.event=="stream_end")]|length)==1
  and ([.[]|select(.event=="stream_end")][0].session_id)==$s
  and ([.[]|select(.event=="stream_end")][0].stream_id)==$t
  and ([.[].event]|join(",")|test("^(token|message)(,(token|message))*?,done,stream_end$"))
' >/dev/null
"$http" GET "$base/api/chat/stream/status?stream_id=$stream" '' "$cookie" | jq -e --arg s "$stream" '.stream_id==$s and .active==false' >/dev/null
"$http" GET "$base/api/session?session_id=$session&messages=1" '' "$cookie" | jq -e --arg s "$session" --arg m "$marker" '.session_id==$s and (.messages|length)==1 and .messages[0].role=="assistant" and (.messages[0].content|contains($m)) and (.messages[0]|has("id") and has("created_at"))' >/dev/null
succeeded=1
