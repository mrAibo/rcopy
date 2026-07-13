#!/usr/bin/env bats

setup_file() {
    export RCOPY_TEST_BIN="${BATS_FILE_TMPDIR}/rcopy"
    go build -o "${RCOPY_TEST_BIN}" .
}

@test "help is available without transfer tools" {
    run "${RCOPY_TEST_BIN}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"safe local and remote file copying"* ]]
}

@test "dry-run prints a safely quoted rsync command" {
    source_file="${BATS_TEST_TMPDIR}/source file"
    touch "${source_file}"

    run env NO_COLOR=1 "${RCOPY_TEST_BIN}" --dry-run --compress --limit 1024 "${source_file}" "host:/backup path"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--bwlimit=1024"* ]]
    [[ "${output}" == *"source file"* ]]
    [[ "${output}" == *"DRY RUN: no changes were made"* ]]
    [[ "${output}" != *$'\033'* ]]
}

@test "scp rejects rsync-only resume mode" {
    source_file="${BATS_TEST_TMPDIR}/source"
    touch "${source_file}"

    run "${RCOPY_TEST_BIN}" --use-scp --resume "${source_file}" host:/backup
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--resume requires rsync"* ]]
}

@test "move cancellation keeps the source" {
    source_file="${BATS_TEST_TMPDIR}/keep-me"
    touch "${source_file}"

    fake_bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${fake_bin}"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}/rsync"
    chmod +x "${fake_bin}/rsync"

    run bash -c "printf 'n\\n' | PATH='${fake_bin}':\"\${PATH}\" '${RCOPY_TEST_BIN}' --move '${source_file}' '${BATS_TEST_TMPDIR}/dest'"
    [ "${status}" -eq 1 ]
    [ -e "${source_file}" ]
    [[ "${output}" == *"operation cancelled"* ]]
}
