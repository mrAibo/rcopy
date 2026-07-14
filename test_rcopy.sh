#!/usr/bin/env bash
# Minimal regression tests for rcopy.sh — no bats dependency.
# Run: bash test_rcopy.sh
# Uses real temp fixtures (validate_inputs rejects nonexistent paths) and temp
# files (not pipes) so rcopy.sh's `set -o pipefail` never aborts the harness.

TEST_DIR=$(mktemp -d)
SRC_FILE="$TEST_DIR/src_file.txt"
SRC_DIR="$TEST_DIR/src_dir"
DST_DIR="$TEST_DIR/dst_dir"
mkdir -p "$SRC_DIR" "$DST_DIR"
echo "fixture" > "$SRC_FILE"
echo "fixture" > "$SRC_DIR/nested.txt"
trap 'rm -rf "$TEST_DIR"' EXIT

source "$(dirname "$0")/rcopy.sh" >/dev/null 2>&1

PASS=0
FAIL=0

# run rcopy (ignore its exit); LAST argument is the output file
capture() {
    local out="${@: -1}";         # last positional = output file
    local args=("${@:1:$#-1}");   # everything before it = command
    "${args[@]}" > "$out" 2>&1 || true
}
count() { grep -c -F -e "$1" "$2"; }   # -F: literal, -- : end of options

assert() {
    local desc=$1 expected=$2 actual=$3
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok  - $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL- $desc"; echo "        expected: [$expected]  actual: [$actual]"
        FAIL=$((FAIL+1))
    fi
}

# --- 1. --user applied to remote specs (was ignored before the fix) --------
capture rcopy --user alice -d "$SRC_DIR" host:/data/ "$TEST_DIR/o1"
assert "--user prepends user@ to source" "1" "$(count 'alice@host' "$TEST_DIR/o1")"

capture rcopy -u bob -d "$SRC_DIR" bobhost:/dest/ "$TEST_DIR/o2"
assert "--user (-u) prepends user@ to dest" "1" "$(count 'bob@bobhost' "$TEST_DIR/o2")"

# --- 1b. -z compression requires a LOCAL source (remote source can't be tarred) ---
capture rcopy -z -d user@xhost:/data /backup/ "$TEST_DIR/o1b"
assert "-z with remote source is rejected" "1" "$(count 'Compression (-z) requires a local source' "$TEST_DIR/o1b")"

# --- 2. -m must NOT delete a remote source (data-loss guard) ---------------
capture rcopy -m -d "$SRC_DIR" xhost:/x/ "$TEST_DIR/o3"
assert "-m remote source: no 'Removing source' in dry-run" "0" "$(count 'Removing source files' "$TEST_DIR/o3")"

capture rcopy -m -d "$SRC_DIR" "$DST_DIR" "$TEST_DIR/o4"
assert "-m local source: MOVE mode shown in dry-run" "1" "$(count 'MOVE' "$TEST_DIR/o4")"

# --- 3. --resume uses --partial only (no --append-verify that corrupts) -----
capture rcopy -r -d "$SRC_DIR" "$DST_DIR" "$TEST_DIR/o5"
assert "--resume preview uses --partial" "1" "$(count 'partial' "$TEST_DIR/o5")"
assert "--resume preview has NO --append-verify" "0" "$(count 'append-verify' "$TEST_DIR/o5")"

# --- 4. NO_COLOR disables ANSI codes ---------------------------------------
NO_COLOR=1 bash -c 'source '"$(dirname "$0")"'/rcopy.sh >/dev/null 2>&1; rcopy --help' > "$TEST_DIR/o6" 2>&1
assert "NO_COLOR strips ANSI codes" "0" "$(count "$(printf '\033')" "$TEST_DIR/o6")"

# --- 5. missing args reported on terminal, not swallowed by --log ----------
capture rcopy -L "$TEST_DIR/never.log" "$TEST_DIR/o7"
assert "missing args reported (not redirected away)" "1" "$(count 'Missing source or destination' "$TEST_DIR/o7")"
rm -f "$TEST_DIR/never.log"

# --- 6. trap EXIT emits no unbound-variable noise --------------------------
capture rcopy -d "$SRC_DIR" "$DST_DIR" "$TEST_DIR/o8"
assert "no 'not set' trap error on exit" "0" "$(count 'ist nicht gesetzt' "$TEST_DIR/o8")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
