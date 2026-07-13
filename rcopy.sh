#!/usr/bin/env bash
# Compatibility shim for users who previously sourced rcopy.sh.
# The implementation now lives in the Go binary.

_rcopy_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_rcopy_binary=${RCOPY_BIN:-"${_rcopy_script_dir}/rcopy"}

rcopy() {
    if [[ -x "${_rcopy_binary}" ]]; then
        "${_rcopy_binary}" "$@"
        return
    fi
    command rcopy "$@"
}

_completion_file="${_rcopy_script_dir}/completions/rcopy.bash"
if [[ -r "${_completion_file}" ]]; then
    # shellcheck source=/dev/null
    source "${_completion_file}"
fi

export -f rcopy
unset _completion_file
printf 'rcopy compatibility function loaded. Type "rcopy --help" for usage.\n'
