package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const version = "0.1.0"

var errUsage = errors.New("invalid command line")

type options struct {
	compress   bool
	move       bool
	dryRun     bool
	force      bool
	resume     bool
	useSCP     bool
	verbose    bool
	syncMode   bool
	user       string
	port       string
	identity   string
	limit      string
	exclude    string
	logFile    string
	sourceHost string
	targetHost string
	days       string
	source     string
	dest       string
}

type command struct {
	name string
	args []string
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	opts, showHelp, err := parseArgs(args)
	if showHelp {
		printHelp(stdout)
		return 0
	}
	if err != nil {
		fmt.Fprintln(stderr, "rcopy:", err)
		fmt.Fprintln(stderr, "Try 'rcopy --help' for usage.")
		return 1
	}

	closer, err := configureLog(opts.logFile, &stdout, &stderr)
	if err != nil {
		fmt.Fprintln(stderr, "rcopy:", err)
		return 1
	}
	if closer != nil {
		defer closer.Close()
	}

	if opts.syncMode {
		if err := runSync(opts, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, "rcopy:", err)
			return 1
		}
		return 0
	}

	if err := validate(opts); err != nil {
		fmt.Fprintln(stderr, "rcopy:", err)
		return 1
	}

	printSummary(stdout, opts)
	cmd, err := buildTransferCommand(opts)
	if err != nil {
		fmt.Fprintln(stderr, "rcopy:", err)
		return 1
	}

	if opts.dryRun {
		fmt.Fprintln(stdout, "Dry run; no changes will be made.")
		fmt.Fprintln(stdout, formatCommand(cmd))
		return 0
	}

	if opts.move && !opts.force {
		ok, err := confirm(stdin, stdout, "This will delete the source after a successful transfer. Continue? [y/N] ")
		if err != nil {
			fmt.Fprintln(stderr, "rcopy:", err)
			return 1
		}
		if !ok {
			fmt.Fprintln(stderr, "rcopy: operation cancelled")
			return 1
		}
	}

	cleanup, transferredSource, err := prepareSource(opts, stdout, stderr)
	if err != nil {
		fmt.Fprintln(stderr, "rcopy:", err)
		return 1
	}
	if cleanup != nil {
		defer cleanup()
	}
	if transferredSource != opts.source {
		opts.source = transferredSource
		cmd, err = buildTransferCommand(opts)
		if err != nil {
			fmt.Fprintln(stderr, "rcopy:", err)
			return 1
		}
	}

	if opts.verbose {
		fmt.Fprintln(stdout, formatCommand(cmd))
	}
	if err := execute(cmd, stdout, stderr); err != nil {
		fmt.Fprintln(stderr, "rcopy: transfer failed:", err)
		return 1
	}

	if opts.compress {
		if err := unpackDestination(opts, transferredSource, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, "rcopy:", err)
			return 1
		}
	}

	if opts.move {
		if err := removeSource(opts.source, transferredSource); err != nil {
			fmt.Fprintln(stderr, "rcopy: transfer succeeded, but source removal failed:", err)
			return 1
		}
	}

	fmt.Fprintln(stdout, "Transfer completed successfully.")
	return 0
}

func parseArgs(args []string) (options, bool, error) {
	var opts options
	var positional []string

	next := func(i *int, name string) (string, error) {
		if *i+1 >= len(args) {
			return "", fmt.Errorf("%s requires an argument", name)
		}
		*i++
		return args[*i], nil
	}

	for i := 0; i < len(args); i++ {
		arg := args[i]
		var value string
		var err error
		switch arg {
		case "-h", "--help", "-?":
			return opts, true, nil
		case "--version":
			fmt.Println("rcopy", version)
			return opts, false, nil
		case "-z", "--compress":
			opts.compress = true
		case "-m", "--move":
			opts.move = true
		case "-d", "--dry-run":
			opts.dryRun = true
		case "-f", "--force":
			opts.force = true
		case "-r", "--resume":
			opts.resume = true
		case "-s", "--use-scp":
			opts.useSCP = true
		case "-v", "--verbose":
			opts.verbose = true
		case "-q", "--quick":
			opts.compress = true
			opts.verbose = true
		case "-S", "--sync":
			opts.syncMode = true
		case "-u", "--user":
			value, err = next(&i, arg)
			opts.user = value
		case "-p", "--port":
			value, err = next(&i, arg)
			opts.port = value
		case "-i", "--identity":
			value, err = next(&i, arg)
			opts.identity = value
		case "-l", "--limit":
			value, err = next(&i, arg)
			opts.limit = value
		case "-e", "--exclude":
			value, err = next(&i, arg)
			opts.exclude = value
		case "-L", "--log":
			value, err = next(&i, arg)
			opts.logFile = value
		case "--source-host":
			value, err = next(&i, arg)
			opts.sourceHost = value
		case "--target-host":
			value, err = next(&i, arg)
			opts.targetHost = value
		case "--days":
			value, err = next(&i, arg)
			opts.days = value
		case "--":
			positional = append(positional, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(arg, "-") {
				return opts, false, fmt.Errorf("unknown option %q", arg)
			}
			positional = append(positional, arg)
		}
		if err != nil {
			return opts, false, err
		}
	}

	if len(positional) != 2 {
		return opts, false, fmt.Errorf("%w: expected source and destination", errUsage)
	}
	opts.source, opts.dest = positional[0], positional[1]
	return opts, false, nil
}

func validate(opts options) error {
	if opts.port != "" {
		port, err := strconv.Atoi(opts.port)
		if err != nil || port < 1 || port > 65535 {
			return fmt.Errorf("port must be between 1 and 65535")
		}
	}
	if opts.limit != "" {
		limit, err := strconv.Atoi(opts.limit)
		if err != nil || limit < 1 {
			return fmt.Errorf("bandwidth limit must be a positive integer")
		}
	}
	if opts.days != "" {
		days, err := strconv.Atoi(opts.days)
		if err != nil || days < 0 {
			return fmt.Errorf("days must be a non-negative integer")
		}
	}
	if opts.identity != "" {
		info, err := os.Stat(opts.identity)
		if err != nil {
			return fmt.Errorf("identity file: %w", err)
		}
		if info.IsDir() {
			return fmt.Errorf("identity file %q is a directory", opts.identity)
		}
	}
	if !isRemote(opts.source) {
		if _, err := os.Stat(opts.source); err != nil {
			return fmt.Errorf("source: %w", err)
		}
	}
	if opts.useSCP && opts.resume {
		return fmt.Errorf("--resume requires rsync")
	}
	if opts.useSCP && opts.limit != "" {
		return fmt.Errorf("--limit requires rsync")
	}
	return nil
}

func buildTransferCommand(opts options) (command, error) {
	source := applyUser(opts.source, opts.user)
	dest := applyUser(opts.dest, opts.user)

	if opts.useSCP {
		args := []string{"-r"}
		if opts.verbose {
			args = append(args, "-v")
		}
		if opts.port != "" {
			args = append(args, "-P", opts.port)
		}
		if opts.identity != "" {
			args = append(args, "-i", opts.identity)
		}
		args = append(args, source, dest)
		return command{name: "scp", args: args}, nil
	}

	args := []string{"-avh", "--info=progress2"}
	if opts.verbose {
		args = append(args, "--stats")
	}
	if opts.resume {
		args = append(args, "--partial", "--append-verify")
	}
	if opts.limit != "" {
		args = append(args, "--bwlimit="+opts.limit)
	}
	if opts.exclude != "" {
		if info, err := os.Stat(opts.exclude); err == nil && !info.IsDir() {
			args = append(args, "--exclude-from="+opts.exclude)
		} else {
			args = append(args, "--exclude="+opts.exclude)
		}
	}
	ssh := sshTransport(opts)
	if len(ssh) > 1 {
		args = append(args, "-e", strings.Join(ssh, " "))
	}
	args = append(args, source, dest)
	return command{name: "rsync", args: args}, nil
}

func prepareSource(opts options, stdout, stderr io.Writer) (func(), string, error) {
	if !opts.compress {
		return nil, opts.source, nil
	}
	if isRemote(opts.source) {
		return nil, "", fmt.Errorf("--compress currently requires a local source")
	}

	tempDir, err := os.MkdirTemp("", "rcopy-")
	if err != nil {
		return nil, "", err
	}
	cleanup := func() { _ = os.RemoveAll(tempDir) }
	archive := filepath.Join(tempDir, filepath.Base(filepath.Clean(opts.source))+".tar.gz")
	args := []string{"-czf", archive, "-C", filepath.Dir(filepath.Clean(opts.source))}
	if opts.exclude != "" {
		if info, statErr := os.Stat(opts.exclude); statErr == nil && !info.IsDir() {
			patterns, readErr := readPatterns(opts.exclude)
			if readErr != nil {
				cleanup()
				return nil, "", readErr
			}
			for _, pattern := range patterns {
				args = append(args, "--exclude="+pattern)
			}
		} else {
			args = append(args, "--exclude="+opts.exclude)
		}
	}
	args = append(args, filepath.Base(filepath.Clean(opts.source)))
	fmt.Fprintln(stdout, "Compressing source...")
	if err := execute(command{name: "tar", args: args}, stdout, stderr); err != nil {
		cleanup()
		return nil, "", fmt.Errorf("compression failed: %w", err)
	}
	return cleanup, archive, nil
}

func unpackDestination(opts options, archive string, stdout, stderr io.Writer) error {
	name := filepath.Base(archive)
	fmt.Fprintln(stdout, "Unpacking destination archive...")
	if isRemote(opts.dest) {
		host, path, err := splitRemote(applyUser(opts.dest, opts.user))
		if err != nil {
			return err
		}
		remoteCommand := "cd " + shellQuote(path) + " && tar -xzf " + shellQuote(name) + " && rm -f -- " + shellQuote(name)
		args := append(sshTransport(opts)[1:], host, remoteCommand)
		return execute(command{name: "ssh", args: args}, stdout, stderr)
	}

	destDir := opts.dest
	if info, err := os.Stat(destDir); err != nil || !info.IsDir() {
		destDir = filepath.Dir(destDir)
	}
	archiveAtDest := filepath.Join(destDir, name)
	if err := execute(command{name: "tar", args: []string{"-xzf", archiveAtDest, "-C", destDir}}, stdout, stderr); err != nil {
		return fmt.Errorf("local decompression failed: %w", err)
	}
	if err := os.Remove(archiveAtDest); err != nil {
		return fmt.Errorf("remove destination archive: %w", err)
	}
	return nil
}

func runSync(opts options, stdout, stderr io.Writer) error {
	if err := validate(opts); err != nil {
		return err
	}
	if opts.sourceHost == "" || opts.targetHost == "" {
		return fmt.Errorf("--source-host and --target-host are required in sync mode")
	}
	if opts.useSCP {
		return fmt.Errorf("sync mode requires rsync")
	}

	tempDir, err := os.MkdirTemp("", "rcopy-sync-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDir)
	listFile := filepath.Join(tempDir, "files.txt")

	find := "find " + shellQuote(opts.source) + " -type f"
	if opts.days != "" {
		find += " -mtime -" + opts.days
	}
	find += " -print"
	list, err := exec.Command("ssh", opts.sourceHost, find).Output()
	if err != nil {
		return fmt.Errorf("create remote file list: %w", err)
	}
	prefix := strings.TrimSuffix(opts.source, "/") + "/"
	lines := strings.Split(string(list), "\n")
	var relative []string
	for _, line := range lines {
		if line == "" {
			continue
		}
		path := strings.TrimPrefix(line, prefix)
		if path == line || strings.HasPrefix(path, "../") {
			return fmt.Errorf("source host returned path outside source: %q", line)
		}
		relative = append(relative, path)
	}
	if len(relative) == 0 {
		fmt.Fprintln(stdout, "No files matched.")
		return nil
	}
	if err := os.WriteFile(listFile, []byte(strings.Join(relative, "\n")+"\n"), 0o600); err != nil {
		return err
	}

	first := command{name: "rsync", args: []string{"-az", "--files-from=" + listFile, opts.sourceHost + ":" + strings.TrimSuffix(opts.source, "/") + "/", tempDir + "/"}}
	second := command{name: "rsync", args: []string{"-az", "--files-from=" + listFile, tempDir + "/", opts.targetHost + ":" + strings.TrimSuffix(opts.dest, "/") + "/"}}
	if opts.dryRun {
		fmt.Fprintln(stdout, formatCommand(first))
		fmt.Fprintln(stdout, formatCommand(second))
		return nil
	}
	if err := execute(first, stdout, stderr); err != nil {
		return fmt.Errorf("copy from source host: %w", err)
	}
	if err := execute(second, stdout, stderr); err != nil {
		return fmt.Errorf("copy to target host: %w", err)
	}
	if opts.move {
		for _, path := range relative {
			remote := filepath.ToSlash(filepath.Join(opts.source, path))
			if err := execute(command{name: "ssh", args: []string{opts.sourceHost, "rm -f -- " + shellQuote(remote)}}, stdout, stderr); err != nil {
				return fmt.Errorf("remove source file %q: %w", path, err)
			}
		}
	}
	fmt.Fprintln(stdout, "Sync completed successfully.")
	return nil
}

func execute(cmd command, stdout, stderr io.Writer) error {
	if _, err := exec.LookPath(cmd.name); err != nil {
		return fmt.Errorf("required command %q not found", cmd.name)
	}
	process := exec.Command(cmd.name, cmd.args...)
	process.Stdout = stdout
	process.Stderr = stderr
	process.Stdin = os.Stdin
	return process.Run()
}

func configureLog(path string, stdout, stderr *io.Writer) (*os.File, error) {
	if path == "" {
		return nil, nil
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open log file: %w", err)
	}
	*stdout = io.MultiWriter(*stdout, file)
	*stderr = io.MultiWriter(*stderr, file)
	return file, nil
}

func confirm(stdin io.Reader, stdout io.Writer, prompt string) (bool, error) {
	fmt.Fprint(stdout, prompt)
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, err
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true, nil
	default:
		return false, nil
	}
}

func removeSource(original, transferred string) error {
	if original != transferred {
		return nil
	}
	if isRemote(original) {
		return fmt.Errorf("moving a remote source is not supported outside sync mode")
	}
	return os.RemoveAll(original)
}

func readPatterns(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var patterns []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			patterns = append(patterns, line)
		}
	}
	return patterns, scanner.Err()
}

func sshTransport(opts options) []string {
	args := []string{"ssh"}
	if opts.port != "" {
		args = append(args, "-p", opts.port)
	}
	if opts.identity != "" {
		args = append(args, "-i", opts.identity)
	}
	return args
}

func applyUser(value, user string) string {
	if user == "" || !isRemote(value) {
		return value
	}
	host, path, err := splitRemote(value)
	if err != nil || strings.Contains(host, "@") {
		return value
	}
	return user + "@" + host + ":" + path
}

func isRemote(value string) bool {
	if len(value) >= 2 && value[1] == ':' {
		return false
	}
	colon := strings.IndexByte(value, ':')
	return colon > 0 && !strings.Contains(value[:colon], string(filepath.Separator))
}

func splitRemote(value string) (string, string, error) {
	colon := strings.IndexByte(value, ':')
	if colon <= 0 || colon == len(value)-1 {
		return "", "", fmt.Errorf("invalid remote path %q", value)
	}
	return value[:colon], value[colon+1:], nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func formatCommand(cmd command) string {
	parts := make([]string, 0, len(cmd.args)+1)
	parts = append(parts, shellQuote(cmd.name))
	for _, arg := range cmd.args {
		parts = append(parts, shellQuote(arg))
	}
	return strings.Join(parts, " ")
}

func printSummary(w io.Writer, opts options) {
	method := "rsync"
	if opts.useSCP {
		method = "scp"
	}
	fmt.Fprintln(w, "Transfer summary")
	fmt.Fprintf(w, "  Source:      %s\n", opts.source)
	fmt.Fprintf(w, "  Destination: %s\n", opts.dest)
	fmt.Fprintf(w, "  Method:      %s\n", method)
	if opts.compress {
		fmt.Fprintln(w, "  Compression: tar.gz")
	}
	if opts.resume {
		fmt.Fprintln(w, "  Resume:      enabled")
	}
	if opts.move {
		fmt.Fprintln(w, "  Mode:        move")
	}
}

func printHelp(w io.Writer) {
	fmt.Fprintln(w, `rcopy - copy files locally or over SSH

Usage:
  rcopy [options] SOURCE DESTINATION

Options:
  -z, --compress           create a tar.gz archive before transfer
  -m, --move               remove source after a successful transfer
  -u, --user USER          add USER to remote paths without one
  -p, --port PORT          SSH port
  -i, --identity FILE      SSH private key
  -l, --limit KBPS         rsync bandwidth limit
  -e, --exclude VALUE      rsync pattern or exclude file
  -s, --use-scp            use scp instead of rsync
  -v, --verbose            print command and detailed transfer statistics
  -d, --dry-run            print the command without changing data
  -f, --force              skip move confirmation
  -r, --resume             resume an interrupted rsync transfer
  -q, --quick              enable compression and verbose output
  -L, --log FILE           append output to FILE
  -S, --sync               stage a server-to-server rsync via this host
      --source-host HOST   source host for sync mode
      --target-host HOST   target host for sync mode
      --days DAYS          sync files modified within DAYS
      --version            print version
  -h, --help               show help

Exit codes:
  0 success
  1 invalid input, cancelled operation, or transfer failure`)
}
