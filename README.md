# rcopy - Remote Copy Tool

`rcopy` is a small Go CLI for local copies, SSH-based remote copies, and staged server-to-server synchronization. It keeps the original command-line flags while replacing the sourced Bash implementation with one static binary.

## Why Go

- one Linux binary with no runtime dependency
- standard-library-only codebase
- static Linux/amd64 and offline builds
- explicit argument construction instead of fragile shell command strings
- testable validation and transfer planning

`rcopy` still delegates data transfer to the proven platform tools `rsync`, `scp`, and `ssh`.

## Build

```bash
gofmt -w .
go mod verify
go test ./...
go vet ./...
GOPROXY=off GOSUMDB=off go build -mod=vendor -o rcopy .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o rcopy-linux-amd64 .
```

No third-party Go module is required. The resulting binary is suitable for SLES when the target system provides the selected transfer tool.

## Install

```bash
install -m 0755 rcopy-linux-amd64 ~/.local/bin/rcopy
```

Optional Bash completion:

```bash
source /path/to/rcopy/completions/rcopy.bash
```

Existing users may continue to source `rcopy.sh`; it is now a small compatibility shim that invokes the Go binary.

## Usage

```text
rcopy [OPTIONS] source destination
```

Important options:

| Option | Meaning |
|---|---|
| `-z`, `--compress` | Enable rsync/scp transport compression |
| `-m`, `--move` | Remove successfully transferred source files |
| `-u`, `--user USER` | Add a user to remote hosts without one |
| `-p`, `--port PORT` | Set the SSH port |
| `-i`, `--identity FILE` | Use an SSH private key |
| `-l`, `--limit RATE` | Limit rsync bandwidth in KiB/s |
| `-e`, `--exclude VALUE` | Use an rsync exclude pattern or file |
| `-s`, `--use-scp` | Use scp instead of rsync |
| `-v`, `--verbose` | Show the command and detailed output |
| `-d`, `--dry-run` | Show the complete operation without executing it |
| `-f`, `--force` | Skip the move confirmation |
| `-r`, `--resume` | Resume a partial rsync transfer |
| `-q`, `--quick` | Enable compression and verbose output |
| `-L`, `--log FILE` | Append output to a log file |
| `-S`, `--sync` | Stage a transfer between two remote hosts |

Run `rcopy --help` for the complete option list.

## Examples

Local copy:

```bash
rcopy ~/documents/project /backup/
```

Copy to a remote host with compression:

```bash
rcopy -z -v ~/documents user@server:/backup/
```

Preview a move operation:

```bash
rcopy --dry-run --move server:/data ./data
```

Exclude log files and use a custom SSH port:

```bash
rcopy -e '*.log' -p 2222 ~/project user@server:/backup/
```

Staged server-to-server sync:

```bash
rcopy --sync --source-host server1 --target-host server2 /src /dest
```

Only files modified in the last seven days:

```bash
rcopy --sync --days 7 --source-host server1 --target-host server2 /src /dest
```

## Safety and compatibility

- Exit status remains `0` for success and `1` for invalid input, cancellation, missing tools, or transfer failure.
- `--move` asks for confirmation unless `--force` is present.
- Rsync move mode uses `--remove-source-files`; excluded or failed files are not deleted.
- Server-to-server move deletes source files only after both copy stages have completed.
- SCP uses its required uppercase `-P` port flag.
- `--exclude`, `--limit`, and `--resume` are rejected with SCP instead of being silently ignored.
- `NO_COLOR` disables ANSI colors.
- Remote paths and SSH commands are quoted before they cross a shell boundary.

## Tests

```bash
go test ./...
go vet ./...
bats tests
```

The GitHub Actions workflow also verifies formatting, module integrity, Bats tests, an offline vendor-only build, and a static Linux/amd64 artifact.

## Possible next improvements

The current version intentionally keeps the first migration small. Good follow-up candidates are resumable transfer profiles, machine-readable `--json` output, checksums after transfer, configurable retry/backoff, and an optional keyboard-only TUI that remains a front end to the same CLI behavior.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
