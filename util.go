package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func (a *application) execute(ctx context.Context, stdin io.Reader, cmd command) error {
	return a.executeTo(ctx, stdin, a.out, cmd)
}

func (a *application) executeTo(ctx context.Context, stdin io.Reader, stdout io.Writer, cmd command) error {
	process := exec.CommandContext(ctx, cmd.name, cmd.args...)
	process.Stdin = stdin
	if process.Stdin == nil {
		process.Stdin = a.in
	}
	process.Stdout = stdout
	process.Stderr = a.errOut
	if err := process.Run(); err != nil {
		return fmt.Errorf("%s: %w", commandString(cmd), err)
	}
	return nil
}

func requireCommands(names ...string) error {
	for _, name := range names {
		if _, err := exec.LookPath(name); err != nil {
			return fmt.Errorf("required command %q was not found in PATH", name)
		}
	}
	return nil
}

func (a *application) confirm(prompt string) (bool, error) {
	fmt.Fprint(a.out, a.yellow(prompt))
	line, err := bufio.NewReader(a.in).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, fmt.Errorf("read confirmation: %w", err)
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true, nil
	default:
		return false, nil
	}
}

func (a *application) printSummary(opts options, source, destination, preview string) {
	fmt.Fprintln(a.out, a.blue("Remote Copy"))
	fmt.Fprintf(a.out, "  Source:      %s\n", source)
	fmt.Fprintf(a.out, "  Destination: %s\n", destination)
	fmt.Fprintf(a.out, "  Method:      %s\n", map[bool]string{true: "scp", false: "rsync"}[opts.useSCP])
	fmt.Fprintf(a.out, "  Mode:        %s\n", map[bool]string{true: "move", false: "copy"}[opts.move])
	if opts.compress {
		fmt.Fprintln(a.out, "  Compression: enabled")
	}
	if opts.resume {
		fmt.Fprintln(a.out, "  Resume:      enabled")
	}
	if opts.limit != 0 {
		fmt.Fprintf(a.out, "  Bandwidth:   %d KiB/s\n", opts.limit)
	}
	if opts.exclude != "" {
		fmt.Fprintf(a.out, "  Exclude:     %s\n", opts.exclude)
	}
	if opts.verbose || opts.dryRun {
		fmt.Fprintf(a.out, "  Command:     %s\n", preview)
	}
}

func (a *application) printSyncSummary(opts options, sourceHost, targetHost string, commands []command) {
	fmt.Fprintln(a.out, a.blue("Remote Sync"))
	fmt.Fprintf(a.out, "  Source:      %s:%s\n", sourceHost, opts.source)
	fmt.Fprintf(a.out, "  Destination: %s:%s\n", targetHost, opts.destination)
	if opts.days != 0 {
		fmt.Fprintf(a.out, "  Modified:    last %d day(s)\n", opts.days)
	}
	fmt.Fprintf(a.out, "  Mode:        %s\n", map[bool]string{true: "move", false: "copy"}[opts.move])
	if opts.verbose || opts.dryRun {
		for _, cmd := range commands {
			fmt.Fprintf(a.out, "  Command:     %s\n", commandString(cmd))
		}
	}
}

func remoteTransfer(source, destination string) bool {
	return isRemote(source) || isRemote(destination)
}

func isRemote(value string) bool {
	_, _, ok := splitRemote(value)
	return ok
}

func splitRemote(value string) (host, path string, ok bool) {
	bracket := strings.IndexByte(value, '[')
	if bracket >= 0 && (bracket == 0 || (strings.HasSuffix(value[:bracket], "@") && !strings.Contains(value[:bracket], "/"))) {
		if end := strings.Index(value[bracket:], "]:"); end >= 0 {
			end += bracket
			return value[:end+1], value[end+2:], true
		}
	}
	index := strings.IndexByte(value, ':')
	if index <= 0 || strings.Contains(value[:index], "/") {
		return "", "", false
	}
	return value[:index], value[index+1:], true
}

func withUser(value, user string) string {
	host, path, ok := splitRemote(value)
	if !ok || user == "" || strings.Contains(host, "@") {
		return value
	}
	return user + "@" + host + ":" + path
}

func addUserToHost(host, user string) string {
	if user == "" || strings.Contains(host, "@") {
		return host
	}
	return user + "@" + host
}

func sshArgs(opts options, host string) []string {
	var args []string
	if opts.port != 0 {
		args = append(args, "-p", strconv.Itoa(opts.port))
	}
	if opts.identity != "" {
		args = append(args, "-i", opts.identity)
	}
	return append(args, host)
}

func sshTransport(opts options) string {
	parts := []string{"ssh"}
	if opts.port != 0 {
		parts = append(parts, "-p", strconv.Itoa(opts.port))
	}
	if opts.identity != "" {
		parts = append(parts, "-i", shellQuote(opts.identity))
	}
	return strings.Join(parts, " ")
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func remoteShellPath(value string) string {
	switch {
	case value == "~":
		return `"$HOME"`
	case strings.HasPrefix(value, "~/"):
		return `"$HOME"/` + shellQuote(strings.TrimPrefix(value, "~/"))
	default:
		return shellQuote(value)
	}
}

func commandString(cmd command) string {
	parts := make([]string, 0, len(cmd.args)+1)
	parts = append(parts, shellQuote(cmd.name))
	for _, arg := range cmd.args {
		parts = append(parts, shellQuote(arg))
	}
	return strings.Join(parts, " ")
}

func trailingSlash(path string) string {
	return strings.TrimRight(path, "/") + "/"
}

func isTerminal(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func (a *application) blue(value string) string   { return a.paint("\x1b[34m", value) }
func (a *application) green(value string) string  { return a.paint("\x1b[32m", value) }
func (a *application) red(value string) string    { return a.paint("\x1b[31m", value) }
func (a *application) yellow(value string) string { return a.paint("\x1b[33m", value) }
func (a *application) paint(code, value string) string {
	if !a.color {
		return value
	}
	return code + value + "\x1b[0m"
}

func helpText() string {
	return `rcopy - safe local and remote file copying

Usage:
  rcopy [OPTIONS] source destination

Options:
  -z, --compress           Enable transport compression
  -m, --move               Remove successfully transferred source files
  -u, --user USER          Add USER to remote hosts without an explicit user
  -p, --port PORT          SSH port
  -i, --identity FILE      SSH private key
  -l, --limit RATE         Rsync bandwidth limit in KiB/s
  -e, --exclude VALUE      Rsync exclude pattern or exclude file
  -s, --use-scp            Use scp instead of rsync
  -v, --verbose            Show command and detailed transfer output
  -d, --dry-run            Show the operation without executing it
  -f, --force              Skip move confirmation
  -r, --resume             Resume partial rsync transfers
  -q, --quick              Enable compression and verbose output
  -L, --log FILE           Append output to FILE
  -S, --sync               Stage a transfer between two remote hosts
      --source-host HOST   Source host for sync mode
      --target-host HOST   Target host for sync mode
      --days DAYS          Sync files modified in the last DAYS days
      --version            Show version
  -h, --help               Show help

Examples:
  rcopy ~/documents /backup/
  rcopy -z -v ~/documents user@server:/backup/
  rcopy --dry-run --move server:/data ./data
  rcopy --sync --source-host server1 --target-host server2 /src /dest

Exit status:
  0  success
  1  invalid input, cancellation, missing tool, or transfer failure
`
}
