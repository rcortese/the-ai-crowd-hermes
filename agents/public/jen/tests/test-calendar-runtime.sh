#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/tools/wrappers/jen-calendar-runtime"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gog" <<'FAKEGOG'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "auth" && "${2:-}" == "doctor" ]]; then
  if [[ "${FAKE_GOG_AUTH_STATUS:-ok}" == "error" ]]; then
    printf 'error\tkeyring.password\tfile keyring selected but GOG_KEYRING_PASSWORD is not set in a non-interactive process\nstatus\terror\n'
  else
    printf 'ok\tkeyring.backend\tfile\nstatus\tok\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "calendar" && "${2:-}" == "time" ]]; then
  printf '{"now":"2026-05-24T12:00:00Z"}\n'; exit 0
fi
if [[ "${1:-}" == "calendar" && "${2:-}" == "events" ]]; then
  printf '{"events":[{"id":"evt1","summary":"Focus","start":{"dateTime":"2026-05-24T13:00:00-03:00"}}]}\n'; exit 0
fi
if [[ "${1:-}" == "calendar" && "${2:-}" == "freebusy" ]]; then
  printf '{"calendars":{"primary":{"busy":[{"start":"2026-05-24T13:00:00-03:00","end":"2026-05-24T14:00:00-03:00"}]}}}\n'; exit 0
fi
if [[ "${1:-}" == "calendar" && "${2:-}" == "event" ]]; then
  printf '{"id":"evt1","summary":"Focus"}\n'; exit 0
fi
printf 'unexpected gog args: %s\n' "$*" >&2
exit 2
FAKEGOG
chmod +x "$TMP/bin/gog"
export PATH="$TMP/bin:$PATH"
export JEN_CALENDAR_RUNTIME_GOG=gog
export JEN_CALENDAR_RUNTIME_GOG_CLIENT=jen-google-test
export GOG_HOME="$TMP/gog"
export GOG_KEYRING_BACKEND=file

assert_json_field() {
  local json="$1" expr="$2" expected="$3"
  got="$(jq -r "$expr" <<<"$json")"
  [[ "$got" == "$expected" ]] || { echo "expected $expr=$expected, got $got in $json" >&2; exit 1; }
}

health="$($RUNTIME health)"
assert_json_field "$health" '.status' ok
assert_json_field "$health" '.live_read_status' ok

export FAKE_GOG_AUTH_STATUS=error
health="$($RUNTIME health)"
assert_json_field "$health" '.status' degraded
assert_json_field "$health" '.live_read_status' auth_failure
unset FAKE_GOG_AUTH_STATUS

list="$($RUNTIME list-events --calendar primary --from 2026-05-24T00:00:00-03:00 --to 2026-05-25T00:00:00-03:00 --max 5)"
assert_json_field "$list" '.status' ok
assert_json_field "$list" '.events[0].id' evt1

busy="$($RUNTIME freebusy --calendar primary --from 2026-05-24T00:00:00-03:00 --to 2026-05-25T00:00:00-03:00)"
assert_json_field "$busy" '.status' ok
assert_json_field "$busy" '.busy[0].start' '2026-05-24T13:00:00-03:00'

event="$($RUNTIME get-event --calendar primary --event-id evt1)"
assert_json_field "$event" '.status' ok
assert_json_field "$event" '.event.id' evt1

set +e
capture="$($RUNTIME capture-event --summary x --from 2026-05-24T13:00:00-03:00 --to 2026-05-24T14:00:00-03:00)"
rc=$?
set -e
[[ $rc -ne 0 ]] || { echo "capture-event unexpectedly succeeded" >&2; exit 1; }
assert_json_field "$capture" '.failure_class' unavailable

set +e
bad_range="$($RUNTIME list-events --calendar primary --from 2026-05-24 --to 2026-05-25)"
bad_range_rc=$?
set -e
[[ $bad_range_rc -ne 0 ]] || { echo "date-only range unexpectedly succeeded" >&2; exit 1; }
assert_json_field "$bad_range" '.failure_class' invalid_argument

set +e
cap_wrap="$($ROOT/tools/wrappers/jen-calendar-capture --summary x --from 2026-05-24T13:00:00-03:00 --to 2026-05-24T14:00:00-03:00)"
cap_wrap_rc=$?
set -e
[[ $cap_wrap_rc -ne 0 ]] || { echo "jen-calendar-capture unexpectedly succeeded" >&2; exit 1; }
assert_json_field "$cap_wrap" '.failure_class' unavailable

for mut in set-reminders delete-event; do
  set +e
  mut_out="$($RUNTIME "$mut" --calendar primary --event-id evt1)"
  mut_rc=$?
  set -e
  [[ $mut_rc -ne 0 ]] || { echo "$mut unexpectedly succeeded" >&2; exit 1; }
  assert_json_field "$mut_out" '.failure_class' unavailable
done

echo "calendar runtime contract smoke: ok"
