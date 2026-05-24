#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TODOIST_ENV_FILE="${TODOIST_ENV_FILE:-/opt/data/.env}"
BASE_URL="https://api.todoist.com/api/v1"
JSON_HEADER='Content-Type: application/json'
DEFAULT_LIMIT=50
MAX_LIMIT=200
INBOX_PROJECT_ID='6Pxjv2q6g9CP77Jc'

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '{"error":"missing_dependency","dependency":"%s"}\n' "$1" >&2
    exit 2
  fi
}

require_bin curl
require_bin jq

if [[ -z "${TODOIST_API_TOKEN:-}" && -f "$TODOIST_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$TODOIST_ENV_FILE"
fi

if [[ -z "${TODOIST_API_TOKEN:-}" ]]; then
  echo '{"error":"missing_token"}' >&2
  exit 2
fi

AUTH_HEADER="Authorization: Bearer ${TODOIST_API_TOKEN}"

error_json() {
  local error="$1"
  local status="${2:-}"
  if [[ -n "$status" ]]; then
    jq -nc --arg error "$error" --argjson status "$status" '{error:$error,status:$status}' >&2
  else
    jq -nc --arg error "$error" '{error:$error}' >&2
  fi
}

require_arg() {
  local value="$1"
  local name="$2"
  if [[ -z "$value" ]]; then
    error_json "missing_argument:$name"
    exit 2
  fi
}

validate_limit() {
  local limit="$1"
  if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
    error_json "invalid_limit"
    exit 2
  fi
  if (( limit < 1 || limit > MAX_LIMIT )); then
    error_json "limit_out_of_range"
    exit 2
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"
  local tmp_body tmp_status curl_status http_status body
  tmp_body="$(mktemp)"
  tmp_status="$(mktemp)"

  if [[ -n "$payload" ]]; then
    curl_status=0
    curl -sS -X "$method" -H "$AUTH_HEADER" -H "$JSON_HEADER" -d "$payload" -o "$tmp_body" -w '%{http_code}' "$url" >"$tmp_status" || curl_status=$?
  else
    curl_status=0
    curl -sS -X "$method" -H "$AUTH_HEADER" -o "$tmp_body" -w '%{http_code}' "$url" >"$tmp_status" || curl_status=$?
  fi

  if (( curl_status != 0 )); then
    rm -f "$tmp_body" "$tmp_status"
    error_json "network_failure"
    exit 3
  fi

  http_status="$(cat "$tmp_status")"
  body="$(cat "$tmp_body")"
  rm -f "$tmp_body" "$tmp_status"

  if [[ "$http_status" =~ ^2 ]]; then
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
    else
      echo '{}'
    fi
    return 0
  fi

  case "$http_status" in
    401|403) error_json "auth_failure" "$http_status" ;;
    404) error_json "not_found" "$http_status" ;;
    429) error_json "rate_limited" "$http_status" ;;
    5*) error_json "server_error" "$http_status" ;;
    *) error_json "request_failed" "$http_status" ;;
  esac
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body" >&2
  fi
  exit 4
}

api_get() {
  api_request GET "$1"
}

api_post() {
  local url="$1"
  local payload="${2:-}"
  api_request POST "$url" "$payload"
}

verify_field() {
  local task_id="$1"
  local jq_expr="$2"
  local expected_json="$3"
  local actual
  actual="$(api_get "$BASE_URL/tasks/$task_id" | jq -c "$jq_expr")"
  if [[ "$actual" != "$expected_json" ]]; then
    jq -nc --arg error "verification_failed" --arg task_id "$task_id" --arg actual "$actual" --arg expected "$expected_json" '{error:$error,task_id:$task_id,actual:$actual,expected:$expected}' >&2
    exit 5
  fi
}

usage() {
  cat <<'EOF'
Usage:
  todoist-api.sh projects
  todoist-api.sh tasks [limit]
  todoist-api.sh tasks-by-project <project_id> [limit]
  todoist-api.sh task <task_id>
  todoist-api.sh labels
  todoist-api.sh find-task <query> [limit]
  todoist-api.sh task-by-content-exact <content> [limit]
  todoist-api.sh overdue [limit]
  todoist-api.sh add-task "content" [project_id]
  todoist-api.sh update-task <task_id> [content] [project_id] [labels_csv] [priority]
  todoist-api.sh update-task-fields <task_id> [content] [description] [priority]
  todoist-api.sh update-description <task_id> <description>
  todoist-api.sh update-due <task_id> <due_string>
  todoist-api.sh update-deadline-date <task_id> <YYYY-MM-DD>
  todoist-api.sh clear-deadline <task_id>
  todoist-api.sh clear-due <task_id>
  todoist-api.sh move-task <task_id> <project_id>
  todoist-api.sh move-task-parent <task_id> <parent_id>
  todoist-api.sh update-labels <task_id> <label1,label2,...>
  todoist-api.sh close-task <task_id>
  todoist-api.sh reopen-task <task_id>
  todoist-api.sh completed-info
  todoist-api.sh completed-by-completion-date <since_rfc3339> <until_rfc3339> [limit]
  todoist-api.sh active-updated-window <since_rfc3339> <until_rfc3339> [limit]
  todoist-api.sh active-snapshot [limit]
  todoist-api.sh activity-window <since_rfc3339> <until_rfc3339> [limit]
  todoist-api.sh due-window <from_date> <to_date> [limit]
  todoist-api.sh clean-overdue-nonreal [limit] [--dry-run]
EOF
}

completed_info_snapshot() {
  api_request POST "$BASE_URL/sync" '{"sync_token":"*","resource_types":["all"]}' | jq '{captured_at:(now|todate), completed_info:(.completed_info // [])}'
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

paged_get_collection() {
  local url="$1"
  local collection_key="$2"
  local tmp_items tmp_next page page_url cursor page_count
  tmp_items="$(mktemp)"
  tmp_next="$(mktemp)"
  printf '[]\n' > "$tmp_items"
  cursor=""
  page_count=0

  while :; do
    page_url="$url"
    if [[ -n "$cursor" ]]; then
      page_url="$page_url&cursor=$(urlencode "$cursor")"
    fi
    page="$(api_get "$page_url")"
    page_count=$((page_count + 1))
    if ! jq -e -c --arg key "$collection_key" --slurpfile acc "$tmp_items" '
      if (.[$key] | type) != "array" then
        empty
      else
        ($acc[0] // []) + .[$key]
      end
    ' <<<"$page" > "$tmp_next"; then
      error_json "provider_shape_invalid"
      exit 6
    fi
    mv "$tmp_next" "$tmp_items"
    tmp_next="$(mktemp)"

    cursor="$(jq -r '.next_cursor // empty' <<<"$page")"
    [[ -z "$cursor" ]] && break
  done

  jq -nc --argjson page_count "$page_count" --arg key "$collection_key" --slurpfile items "$tmp_items" '
    {($key):($items[0] // []), next_cursor:null, complete:true, page_count:$page_count}
  '
  rm -f "$tmp_items" "$tmp_next"
}

cmd="${1:-}"
case "$cmd" in
  projects)
    api_get "$BASE_URL/projects"
    ;;
  tasks)
    limit="${2:-$DEFAULT_LIMIT}"
    validate_limit "$limit"
    api_get "$BASE_URL/tasks?limit=$limit"
    ;;
  tasks-by-project)
    project_id="${2:-}"
    limit="${3:-$DEFAULT_LIMIT}"
    require_arg "$project_id" "project_id"
    validate_limit "$limit"
    api_get "$BASE_URL/tasks?limit=$MAX_LIMIT" | jq --arg project_id "$project_id" --argjson limit "$limit" '
      .results | map(select(.project_id == $project_id)) | .[:$limit]
    '
    ;;
  task)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  labels)
    api_get "$BASE_URL/labels"
    ;;
  find-task)
    query="${2:-}"
    limit="${3:-20}"
    require_arg "$query" "query"
    validate_limit "$limit"
    api_get "$BASE_URL/tasks?limit=$MAX_LIMIT" | jq --arg q "$query" --argjson limit "$limit" '
      .results
      | map(select(.content | ascii_downcase | contains($q | ascii_downcase)))
      | .[:$limit]
    '
    ;;
  task-by-content-exact)
    content="${2:-}"
    limit="${3:-20}"
    require_arg "$content" "content"
    validate_limit "$limit"
    api_get "$BASE_URL/tasks?limit=$MAX_LIMIT" | jq --arg content "$content" --argjson limit "$limit" '
      .results | map(select(.content == $content)) | .[:$limit]
    '
    ;;
  overdue)
    limit="${2:-$MAX_LIMIT}"
    validate_limit "$limit"
    today="$(date +%F)"
    api_get "$BASE_URL/tasks?limit=$limit" | jq --arg today "$today" '
      .results | map(select(.due != null and .due.date < $today))
    '
    ;;
  add-task)
    content="${2:-}"
    project_id="${3:-}"
    require_arg "$content" "content"
    if [[ -n "$project_id" ]]; then
      payload=$(jq -nc --arg content "$content" --arg project_id "$project_id" '{content:$content,project_id:$project_id}')
    else
      payload=$(jq -nc --arg content "$content" '{content:$content}')
    fi
    api_post "$BASE_URL/tasks" "$payload"
    ;;
  update-task)
    task_id="${2:-}"
    content="${3:-}"
    project_id="${4:-}"
    labels_csv="${5:-}"
    priority="${6:-}"
    require_arg "$task_id" "task_id"
    current="$(api_get "$BASE_URL/tasks/$task_id")"
    new_content="$(jq -r '.content' <<<"$current")"
    new_labels="$(jq -c '.labels' <<<"$current")"
    new_priority="$(jq -r '.priority' <<<"$current")"
    current_project_id="$(jq -r '.project_id' <<<"$current")"
    if [[ -n "$content" ]]; then new_content="$content"; fi
    if [[ -n "$labels_csv" ]]; then
      new_labels="$(printf '%s' "$labels_csv" | jq -Rnc 'input | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0))')"
    fi
    if [[ -n "$priority" ]]; then new_priority="$priority"; fi
    payload=$(jq -nc --arg content "$new_content" --argjson labels "$new_labels" --argjson priority "$new_priority" '{content:$content,labels:$labels,priority:$priority}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    if [[ -n "$project_id" && "$project_id" != "$current_project_id" ]]; then
      move_payload=$(jq -nc --arg project_id "$project_id" '{project_id:$project_id}')
      api_post "$BASE_URL/tasks/$task_id/move" "$move_payload" >/dev/null
    fi
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  update-task-fields)
    task_id="${2:-}"
    content="${3:-}"
    description="${4:-}"
    priority="${5:-}"
    require_arg "$task_id" "task_id"
    payload="$(jq -nc \
      --arg content "$content" \
      --arg description "$description" \
      --arg priority "$priority" \
      '({}
        + (if $content != "" then {content:$content} else {} end)
        + (if $description != "" then {description:$description} else {} end)
        + (if $priority != "" then {priority:($priority|tonumber)} else {} end))')"
    if [[ "$payload" == '{}' ]]; then
      error_json "missing_update_fields"
      exit 2
    fi
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  update-description)
    task_id="${2:-}"
    description="${3-}"
    require_arg "$task_id" "task_id"
    if [[ $# -lt 3 ]]; then
      error_json "missing_description"
      exit 2
    fi
    payload="$(jq -nc --arg description "$description" '{description:$description}')"
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    expected="$(jq -nc --arg description "$description" '$description')"
    verify_field "$task_id" '.description' "$expected"
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  update-due)
    task_id="${2:-}"
    due_string="${3:-}"
    require_arg "$task_id" "task_id"
    require_arg "$due_string" "due_string"
    current_task="$(api_get "$BASE_URL/tasks/$task_id")"
    current_due_is_recurring="$(jq -r '.due.is_recurring // false' <<<"$current_task")"
    due_string_recurs=false
    if [[ "$due_string" =~ (^|[[:space:]])(todo|toda|todos|todas|cada|every|daily|weekly|monthly|yearly|diariamente|semanal|mensal|anual)([[:space:]]|$) ]]; then
      due_string_recurs=true
    fi
    if [[ "$current_due_is_recurring" == "true" && "$due_string_recurs" != "true" && "${JEN_TODOIST_ALLOW_RECURRING_DUE_OVERWRITE:-}" != "1" ]]; then
      jq -nc --arg error "recurring_due_overwrite_blocked" --arg task_id "$task_id" --arg due_string "$due_string" '{error:$error,task_id:$task_id,due_string:$due_string,allow_override_env:"JEN_TODOIST_ALLOW_RECURRING_DUE_OVERWRITE=1"}' >&2
      exit 6
    fi
    payload=$(jq -nc --arg due_string "$due_string" '{due_string:$due_string}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    expected_due="$(jq -nc --arg due "$due_string" '$due')"
    actual_task="$(api_get "$BASE_URL/tasks/$task_id")"
    actual_due="$(jq -c '.due.string // empty' <<<"$actual_task")"
    if [[ "$actual_due" != "$expected_due" ]]; then
      jq -nc --arg error "verification_failed" --arg task_id "$task_id" --arg actual "$actual_due" --arg expected "$expected_due" '{error:$error,task_id:$task_id,actual:$actual,expected:$expected}' >&2
      exit 5
    fi
    printf '%s\n' "$actual_task"
    ;;
  update-deadline-date)
    task_id="${2:-}"
    deadline_date="${3:-}"
    require_arg "$task_id" "task_id"
    require_arg "$deadline_date" "deadline_date"
    if ! [[ "$deadline_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      error_json "invalid_deadline_date"
      exit 2
    fi
    payload=$(jq -nc --arg deadline_date "$deadline_date" '{deadline_date:$deadline_date}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    actual_task="$(api_get "$BASE_URL/tasks/$task_id")"
    actual_deadline="$(jq -r '.deadline.date // empty' <<<"$actual_task")"
    if [[ "$actual_deadline" != "$deadline_date" ]]; then
      jq -nc --arg error "verification_failed" --arg task_id "$task_id" --arg actual "$actual_deadline" --arg expected "$deadline_date" '{error:$error,task_id:$task_id,actual:$actual,expected:$expected}' >&2
      exit 5
    fi
    printf '%s\n' "$actual_task"
    ;;
  clear-deadline)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    payload=$(jq -nc '{deadline_date:null}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    verify_field "$task_id" '.deadline' 'null'
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  clear-due)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    payload=$(jq -nc '{due_string:"no date"}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    verify_field "$task_id" '.due' 'null'
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  move-task)
    task_id="${2:-}"
    project_id="${3:-}"
    require_arg "$task_id" "task_id"
    require_arg "$project_id" "project_id"
    payload=$(jq -nc --arg project_id "$project_id" '{project_id:$project_id}')
    api_post "$BASE_URL/tasks/$task_id/move" "$payload" >/dev/null
    verify_field "$task_id" '.project_id' "\"$project_id\""
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  move-task-parent)
    task_id="${2:-}"
    parent_id="${3:-}"
    require_arg "$task_id" "task_id"
    require_arg "$parent_id" "parent_id"
    payload=$(jq -nc --arg parent_id "$parent_id" '{parent_id:$parent_id}')
    api_post "$BASE_URL/tasks/$task_id/move" "$payload" >/dev/null
    verify_field "$task_id" '.parent_id' "\"$parent_id\""
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  update-labels)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    if [[ $# -lt 3 ]]; then
      error_json "missing_labels"
      exit 2
    fi
    labels_csv="${3:-}"
    expected="$(jq -nc --arg labels_csv "$labels_csv" '$labels_csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0)) | unique | sort')"
    payload=$(jq -nc --argjson labels "$expected" '{labels:$labels}')
    api_post "$BASE_URL/tasks/$task_id" "$payload" >/dev/null
    actual_task="$(api_get "$BASE_URL/tasks/$task_id")"
    actual_labels="$(jq -c '.labels | if type == "array" then (unique | sort) else . end' <<<"$actual_task")"
    if [[ "$actual_labels" != "$expected" ]]; then
      jq -nc --arg error "verification_failed" --arg task_id "$task_id" --arg actual "$actual_labels" --arg expected "$expected" '{error:$error,task_id:$task_id,actual:$actual,expected:$expected}' >&2
      exit 5
    fi
    printf '%s\n' "$actual_task"
    ;;
  close-task)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    api_post "$BASE_URL/tasks/$task_id/close" >/dev/null
    echo '{}'
    ;;
  reopen-task)
    task_id="${2:-}"
    require_arg "$task_id" "task_id"
    api_post "$BASE_URL/tasks/$task_id/reopen" >/dev/null
    api_get "$BASE_URL/tasks/$task_id"
    ;;
  completed-info)
    completed_info_snapshot
    ;;
  completed-by-completion-date)
    since="${2:-}"
    until="${3:-}"
    limit="${4:-$DEFAULT_LIMIT}"
    require_arg "$since" "since"
    require_arg "$until" "until"
    validate_limit "$limit"
    paged_get_collection "$BASE_URL/tasks/completed/by_completion_date?since=$(urlencode "$since")&until=$(urlencode "$until")&limit=$limit" items
    ;;

  active-snapshot)
    limit="${2:-$MAX_LIMIT}"
    validate_limit "$limit"
    paged_get_collection "$BASE_URL/tasks?limit=$limit" results
    ;;
  active-updated-window)
    since="${2:-}"
    until="${3:-}"
    limit="${4:-$MAX_LIMIT}"
    require_arg "$since" "since"
    require_arg "$until" "until"
    validate_limit "$limit"
    paged_get_collection "$BASE_URL/tasks?limit=$limit" results | jq --arg since "$since" --arg until "$until" '
      .results |= map(select((.updated_at // null) != null and .updated_at >= $since and .updated_at <= $until))
    '
    ;;
  activity-window)
    since="${2:-}"
    until="${3:-}"
    limit="${4:-100}"
    require_arg "$since" "since"
    require_arg "$until" "until"
    validate_limit "$limit"
    if (( limit > 100 )); then
      error_json "limit_out_of_range"
      exit 2
    fi
    paged_get_collection "$BASE_URL/activities?date_from=$(urlencode "$since")&date_to=$(urlencode "$until")&limit=$limit&object_event_types=$(urlencode "item:")" results | jq '
      .results |= map(select(
        ((.object_type // .object_type_name // .object?.type // null) == "item")
        or ((.object_event_type // .event_type // .event_name // "") | startswith("item:"))
        or ((.object_type // null) == null and ((.event_type // .event_name // "") | IN("added","updated","deleted","completed","uncompleted","moved","reordered")))
      ))
    '
    ;;
  due-window)
    from_date="${2:-}"
    to_date="${3:-}"
    limit="${4:-$MAX_LIMIT}"
    require_arg "$from_date" "from_date"
    require_arg "$to_date" "to_date"
    validate_limit "$limit"
    paged_get_collection "$BASE_URL/tasks?limit=$limit" results | jq --arg from_date "$from_date" --arg to_date "$to_date" '
      .results |= map(select(.due != null and .due.date >= $from_date and .due.date <= $to_date))
    '
    ;;
  clean-overdue-nonreal)
    limit="${2:-$MAX_LIMIT}"
    dry_run="${3:-}"
    if [[ "$limit" == "--dry-run" ]]; then
      dry_run='--dry-run'
      limit="$MAX_LIMIT"
    fi
    validate_limit "$limit"
    today="$(date +%F)"
    esta_semana_id="$(api_get "$BASE_URL/projects" | jq -r '.results[] | select(.name == "Esta Semana") | .id')"
    if [[ -z "$esta_semana_id" || "$esta_semana_id" == "null" ]]; then
      error_json "missing_project:Esta Semana"
      exit 2
    fi
    api_get "$BASE_URL/tasks?limit=$limit" | jq -c --arg today "$today" '
      .results[]
      | select(.due != null and .due.is_recurring != true and .due.date < $today)
      | {id, content, project_id, due}
    ' | while IFS= read -r item; do
      task_id="$(jq -r '.id' <<<"$item")"
      project_id="$(jq -r '.project_id' <<<"$item")"
      moved=false
      if [[ "$dry_run" != "--dry-run" ]]; then
        api_post "$BASE_URL/tasks/$task_id" '{"due_string":"no date"}' >/dev/null
        verify_field "$task_id" '.due' 'null'
        if [[ "$project_id" == "$INBOX_PROJECT_ID" ]]; then
          payload=$(jq -nc --arg project_id "$esta_semana_id" '{project_id:$project_id}')
          api_post "$BASE_URL/tasks/$task_id/move" "$payload" >/dev/null
          verify_field "$task_id" '.project_id' "\"$esta_semana_id\""
          moved=true
        fi
      else
        if [[ "$project_id" == "$INBOX_PROJECT_ID" ]]; then
          moved=true
        fi
      fi
      jq -nc --argjson task "$item" --argjson moved "$moved" --arg mode "${dry_run:---apply}" '{status:"cleaned_overdue_nonreal",mode:$mode,moved_to_esta_semana:$moved,task:$task}'
    done
    ;;
  *)
    usage
    exit 1
    ;;
esac
