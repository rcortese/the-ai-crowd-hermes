#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
adapter="$repo_root/tools/todoist/todoist-api.sh"
mock_dir=$(mktemp -d)

cleanup() {
  rm -rf "$mock_dir"
}
trap cleanup EXIT

cat > "$mock_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body_file=""
status_format=""
payload=""
url="${*: -1}"
while (($#)); do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -w)
      status_format="$2"
      shift 2
      ;;
    -d)
      payload="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "${TODOIST_TEST_MODE:-success}" in
  active_snapshot_paginated)
    if [[ "$url" == *'cursor='* ]]; then
      body='{"results":[{"id":"active-2","content":"Active 2"}],"next_cursor":null}'
    else
      body='{"results":[{"id":"active-1","content":"Active 1"}],"next_cursor":"active cursor"}'
    fi
    ;;
  active_snapshot_bad_shape)
    body='{"items":[{"id":"wrong"}],"next_cursor":null}'
    ;;
  completed_paginated)
    if [[ "$url" == *'cursor='* ]]; then
      body='{"items":[{"id":"done-2","content":"Done 2"}],"next_cursor":null}'
    else
      body='{"items":[{"id":"done-1","content":"Done 1"}],"next_cursor":"cursor two"}'
    fi
    ;;
  completed_bad_shape)
    body='{"results":[{"id":"wrong"}],"next_cursor":null}'
    ;;
  due_paginated)
    if [[ "$url" == *'cursor='* ]]; then
      body='{"results":[{"id":"due-2","content":"Due 2","due":{"date":"2026-04-26"}}],"next_cursor":null}'
    else
      body='{"results":[{"id":"out","content":"Out","due":{"date":"2026-05-02"}},{"id":"due-1","content":"Due 1","due":{"date":"2026-04-25"}}],"next_cursor":"next cursor"}'
    fi
    ;;
  due_bad_shape)
    body='{"items":[{"id":"wrong"}],"next_cursor":null}'
    ;;
  label_order_current)
    body='{"id":"label-task","labels":["home","errands"]}'
    ;;
  label_clear_current)
    body='{"id":"label-task","labels":[]}'
    ;;
  *)
    body='{"error":"unknown mode"}'
    ;;
esac

if [[ -n "$body_file" ]]; then
  printf '%s' "$body" > "$body_file"
else
  printf '%s' "$body"
fi
[[ -n "$status_format" ]] && printf '200'
EOF
chmod +x "$mock_dir/curl"

assert_jq() {
  local json="$1"
  local filter="$2"
  local message="$3"
  if ! jq -e "$filter" <<<"$json" >/dev/null; then
    echo "assertion failed: $message" >&2
    echo "$json" >&2
    exit 1
  fi
}

active_json=$(PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=active_snapshot_paginated \
  "$adapter" active-snapshot 1)
assert_jq "$active_json" '.results | map(.id) == ["active-1","active-2"]' 'active-snapshot aggregates paginated results'
assert_jq "$active_json" '.complete == true and .page_count == 2 and .next_cursor == null' 'active-snapshot reports complete pagination'

completed_json=$(PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=completed_paginated \
  "$adapter" completed-by-completion-date 2026-04-24T00:00:00Z 2026-04-25T00:00:00Z 1)
assert_jq "$completed_json" '.items | map(.id) == ["done-1","done-2"]' 'completed endpoint aggregates paginated items'
assert_jq "$completed_json" '.complete == true and .page_count == 2 and .next_cursor == null' 'completed endpoint reports complete pagination'

due_json=$(PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=due_paginated \
  "$adapter" due-window 2026-04-24 2026-04-27 1)
assert_jq "$due_json" '.results | map(.id) == ["due-1","due-2"]' 'due-window filters after aggregating all pages'
assert_jq "$due_json" '.complete == true and .page_count == 2 and .next_cursor == null' 'due-window reports complete pagination'

labels_json=$(PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=label_order_current \
  "$adapter" update-labels label-task ' errands,home,errands ')
assert_jq "$labels_json" '.id == "label-task" and (.labels | sort) == ["errands","home"]' 'update-labels verifies labels independent of provider order'

clear_labels_json=$(PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=label_clear_current \
  "$adapter" update-labels label-task '')
assert_jq "$clear_labels_json" '.id == "label-task"' 'update-labels accepts explicit empty label csv as clear-all intent'

set +e
PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=label_order_current \
  "$adapter" update-labels label-task >/tmp/todoist-labels-missing.out 2>/tmp/todoist-labels-missing.err
labels_missing_status=$?
set -e
if [[ "$labels_missing_status" == "0" ]]; then
  echo 'assertion failed: update-labels missing labels argument must fail' >&2
  cat /tmp/todoist-labels-missing.out >&2
  exit 1
fi
assert_jq "$(cat /tmp/todoist-labels-missing.err)" '.error == "missing_labels"' 'update-labels missing labels emits structured error'

set +e
PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=active_snapshot_bad_shape \
  "$adapter" active-snapshot 1 >/tmp/todoist-active-bad.out 2>/tmp/todoist-active-bad.err
active_bad_status=$?
set -e
if [[ "$active_bad_status" == "0" ]]; then
  echo 'assertion failed: active-snapshot bad provider shape must fail' >&2
  cat /tmp/todoist-active-bad.out >&2
  exit 1
fi
assert_jq "$(cat /tmp/todoist-active-bad.err)" '.error == "provider_shape_invalid"' 'active-snapshot bad shape emits structured error'

set +e
PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=completed_bad_shape \
  "$adapter" completed-by-completion-date 2026-04-24T00:00:00Z 2026-04-25T00:00:00Z 1 >/tmp/todoist-completed-bad.out 2>/tmp/todoist-completed-bad.err
completed_bad_status=$?
set -e
if [[ "$completed_bad_status" == "0" ]]; then
  echo 'assertion failed: completed bad provider shape must fail' >&2
  cat /tmp/todoist-completed-bad.out >&2
  exit 1
fi
assert_jq "$(cat /tmp/todoist-completed-bad.err)" '.error == "provider_shape_invalid"' 'completed bad shape emits structured error'

set +e
PATH="$mock_dir:$PATH" TODOIST_API_TOKEN=dummy TODOIST_TEST_MODE=due_bad_shape \
  "$adapter" due-window 2026-04-24 2026-04-27 1 >/tmp/todoist-due-bad.out 2>/tmp/todoist-due-bad.err
due_bad_status=$?
set -e
if [[ "$due_bad_status" == "0" ]]; then
  echo 'assertion failed: due-window bad provider shape must fail' >&2
  cat /tmp/todoist-due-bad.out >&2
  exit 1
fi
assert_jq "$(cat /tmp/todoist-due-bad.err)" '.error == "provider_shape_invalid"' 'due bad shape emits structured error'

rm -f /tmp/todoist-active-bad.out /tmp/todoist-active-bad.err /tmp/todoist-completed-bad.out /tmp/todoist-completed-bad.err /tmp/todoist-due-bad.out /tmp/todoist-due-bad.err /tmp/todoist-labels-missing.out /tmp/todoist-labels-missing.err

echo 'ok - todoist-api pagination contract'
