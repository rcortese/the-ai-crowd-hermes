#!/usr/bin/env bash
# Shared state-path policy for Jen runtime scripts.

jen_require_local_state_path() {
  local candidate="${1:?state path required}" resolved
  resolved="$(realpath -m -- "$candidate")" || return 64
  case "$resolved" in
    /mnt/hermes-shared|/mnt/hermes-shared/*)
      echo "jen_state_path_policy_error: shared_state_path_forbidden" >&2
      return 64
      ;;
  esac
  printf '%s\n' "$resolved"
}
