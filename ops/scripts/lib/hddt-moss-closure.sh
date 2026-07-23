#!/usr/bin/env bash
set -Eeuo pipefail
hddt_source_closure(){
 local root=${1:?release source required} manifest="$1/ops/manifests/moss-release-source-closure.paths" git_bin=${HDDT_GIT_BIN:-git}
 [[ -d $root && ! -L $root && -f $manifest && ! -L $manifest ]] || return 65
 local -a paths=() path; mapfile -t paths <"$manifest"; ((${#paths[@]} > 0)) || return 65
 LC_ALL=C sort -cu "$manifest" >/dev/null || return 65
 for path in "${paths[@]}"; do [[ -n $path && $path != /* && $path != *..* ]] || return 65; "$git_bin" -c safe.directory="$root" -C "$root" ls-files --error-unmatch -- "$path" >/dev/null || return 65; done
 "$git_bin" -c safe.directory="$root" -C "$root" ls-tree -r --full-tree HEAD -- "${paths[@]}" | sha256sum | cut -d' ' -f1
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then hddt_source_closure "${1:?release source required}"; fi
