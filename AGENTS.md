# rcopy contributor rules

Follow the Ponytail rules from `DietrichGebert/ponytail/AGENTS.md`.

Project-specific constraints:

- Keep the CLI as the primary automation interface and preserve existing flags and exit codes.
- Prefer the Go standard library and native Linux tools. Do not add a dependency without a concrete need.
- Preserve offline and vendor-only builds for SLES.
- Read callers, tests, configuration, and workflows before changing a shared code path.
- Fix root causes with the smallest safe diff. Do not weaken validation, quoting, error handling, data-loss protection, security, or keyboard accessibility.
- Add one small executable regression test for non-trivial behavior.
- Do not use Python helpers, generated Base64 patches, or self-modifying workflows.
- Run `gofmt`, `go mod verify`, `go test ./...`, `go vet ./...`, Bats tests, a vendor-only build, and a static Linux/amd64 build after changes.
