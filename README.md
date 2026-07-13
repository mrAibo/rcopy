# rcopy — Remote Copy Tool

`rcopy` is a small Linux CLI for copying files and directories locally or over SSH. It uses the native `rsync`, `scp`, `ssh`, and `tar` tools instead of reimplementing transfer protocols.

The repository now contains:

- `main.go`: the dependency-free Go CLI
- `rcopy.sh`: the original Bash function, retained for compatibility
- `main_test.go`: command-line and command-construction regression tests
- `test/cli.bats`: executable CLI smoke tests

## Build

```bash
go build -o rcopy .
```

Static Linux/amd64 build:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' -o rcopy-linux-amd64 .
```

Offline/vendor-only build for SLES:

```bash
GOPROXY=off GOSUMDB=off go build -mod=vendor -o rcopy .
```

The Go implementation has no third-party dependencies, so no generated vendor source is required.

## Usage

```text
rcopy [options] SOURCE DESTINATION
```

Examples:

```bash
rcopy ~/documents/project /backup/
rcopy ~/documents user@server:/backup/
rcopy user@server:/remote/data ~/local/
rcopy --dry-run --resume ~/large-data server:/backup/
rcopy --exclude '*.log' --port 2222 ~/project user@server:/backup/
rcopy --sync --source-host server1 --target-host server2 /source/path /target/path
```

Important options:

```text
-z, --compress           create a tar.gz archive before transfer
-m, --move               remove source after a successful transfer
-u, --user USER          add USER to remote paths without one
-p, --port PORT          SSH port
-i, --identity FILE      SSH private key
-l, --limit KBPS         rsync bandwidth limit
-e, --exclude VALUE      rsync pattern or exclude file
-s, --use-scp            use scp instead of rsync
-v, --verbose            detailed command and transfer output
-d, --dry-run            print the command without changing data
-f, --force              skip move confirmation
-r, --resume             resume an interrupted rsync transfer
-q, --quick              compression plus verbose output
-L, --log FILE           append output to a log file
-S, --sync               stage server-to-server transfer through this host
```

Run `rcopy --help` for the complete interface.

## Runtime requirements

The binary itself is statically compilable. Transfer operations still require the platform tools used by the selected mode:

- default transfers: `rsync`
- SCP mode: `scp`
- remote operations: `ssh`
- compression: `tar`

## Tests

```bash
gofmt -w .
go mod verify
go test ./...
go vet ./...
bats test
GOPROXY=off GOSUMDB=off go build -mod=vendor -o dist/rcopy-vendor .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/rcopy-linux-amd64 .
```

GitHub Actions uploads the static binary as the artifact `rcopy-linux-amd64`.

## Compatibility

The original `rcopy.sh` remains available and is not removed by the Go migration. Existing automation can migrate to the binary independently.

## License

GNU General Public License v3.0.
