#!/usr/bin/env bats

setup() {
  export RCOPY="$BATS_TEST_TMPDIR/rcopy"
  go build -o "$RCOPY" .
}

@test "help is available" {
  run "$RCOPY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "missing operands return exit code 1" {
  run "$RCOPY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected source and destination"* ]]
}

@test "unknown options return exit code 1" {
  run "$RCOPY" --does-not-exist source destination
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "version is available" {
  run "$RCOPY" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "rcopy 0.1.0" ]]
}
