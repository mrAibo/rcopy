package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

type options struct {
	compress    bool
	move        bool
	user        string
	port        int
	identity    string
	limit       int
	exclude     string
	useSCP      bool
	verbose     bool
	dryRun      bool
	force       bool
	resume      bool
	quick       bool
	logFile     string
	syncMode    bool
	sourceHost  string
	targetHost  string
	days        int
	showHelp    bool
	showVersion bool
	source      string
	destination string
}

func parseOptions(args []string) (options, error) {
	args = interspersedArgs(args)
	var opts options
	fs := flag.NewFlagSet("rcopy", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	fs.BoolVar(&opts.compress, "z", false, "compress during transfer")
	fs.BoolVar(&opts.compress, "compress", false, "compress during transfer")
	fs.BoolVar(&opts.move, "m", false, "move instead of copy")
	fs.BoolVar(&opts.move, "move", false, "move instead of copy")
	fs.StringVar(&opts.user, "u", "", "remote username")
	fs.StringVar(&opts.user, "user", "", "remote username")
	fs.IntVar(&opts.port, "p", 0, "SSH port")
	fs.IntVar(&opts.port, "port", 0, "SSH port")
	fs.StringVar(&opts.identity, "i", "", "SSH identity file")
	fs.StringVar(&opts.identity, "identity", "", "SSH identity file")
	fs.IntVar(&opts.limit, "l", 0, "rsync bandwidth limit in KiB/s")
	fs.IntVar(&opts.limit, "limit", 0, "rsync bandwidth limit in KiB/s")
	fs.StringVar(&opts.exclude, "e", "", "exclude pattern or file")
	fs.StringVar(&opts.exclude, "exclude", "", "exclude pattern or file")
	fs.BoolVar(&opts.useSCP, "s", false, "use scp")
	fs.BoolVar(&opts.useSCP, "use-scp", false, "use scp")
	fs.BoolVar(&opts.verbose, "v", false, "verbose output")
	fs.BoolVar(&opts.verbose, "verbose", false, "verbose output")
	fs.BoolVar(&opts.dryRun, "d", false, "show what would run")
	fs.BoolVar(&opts.dryRun, "dry-run", false, "show what would run")
	fs.BoolVar(&opts.force, "f", false, "skip confirmation")
	fs.BoolVar(&opts.force, "force", false, "skip confirmation")
	fs.BoolVar(&opts.resume, "r", false, "resume partial rsync transfers")
	fs.BoolVar(&opts.resume, "resume", false, "resume partial rsync transfers")
	fs.BoolVar(&opts.quick, "q", false, "enable compression and verbose output")
	fs.BoolVar(&opts.quick, "quick", false, "enable compression and verbose output")
	fs.StringVar(&opts.logFile, "L", "", "append output to file")
	fs.StringVar(&opts.logFile, "log", "", "append output to file")
	fs.BoolVar(&opts.syncMode, "S", false, "sync between two remote hosts")
	fs.BoolVar(&opts.syncMode, "sync", false, "sync between two remote hosts")
	fs.StringVar(&opts.sourceHost, "source-host", "", "sync source host")
	fs.StringVar(&opts.targetHost, "target-host", "", "sync target host")
	fs.IntVar(&opts.days, "days", 0, "only sync files modified in the last N days")
	fs.BoolVar(&opts.showHelp, "h", false, "show help")
	fs.BoolVar(&opts.showHelp, "?", false, "show help")
	fs.BoolVar(&opts.showHelp, "help", false, "show help")
	fs.BoolVar(&opts.showVersion, "version", false, "show version")

	if err := fs.Parse(args); err != nil {
		return options{}, fmt.Errorf("parse options: %w", err)
	}
	if opts.quick {
		opts.compress = true
		opts.verbose = true
	}
	if opts.showHelp || opts.showVersion {
		return opts, nil
	}
	if fs.NArg() != 2 {
		return options{}, fmt.Errorf("expected source and destination; usage: rcopy [OPTIONS] source destination")
	}
	opts.source = fs.Arg(0)
	opts.destination = fs.Arg(1)
	return opts, nil
}

func interspersedArgs(args []string) []string {
	valueFlags := map[string]bool{
		"-u": true, "--user": true, "-p": true, "--port": true,
		"-i": true, "--identity": true, "-l": true, "--limit": true,
		"-e": true, "--exclude": true, "-L": true, "--log": true,
		"--source-host": true, "--target-host": true, "--days": true,
	}
	var flags, positional []string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--" {
			positional = append(positional, args[index+1:]...)
			break
		}
		if strings.HasPrefix(arg, "-") && arg != "-" {
			flags = append(flags, arg)
			name := arg
			if equals := strings.IndexByte(arg, '='); equals >= 0 {
				name = arg[:equals]
			}
			if valueFlags[name] && !strings.Contains(arg, "=") && index+1 < len(args) {
				index++
				flags = append(flags, args[index])
			}
			continue
		}
		positional = append(positional, arg)
	}
	result := append(flags, "--")
	return append(result, positional...)
}

func validateOptions(opts options) error {
	if opts.port < 0 || opts.port > 65535 {
		return fmt.Errorf("port must be between 1 and 65535")
	}
	if opts.limit < 0 {
		return fmt.Errorf("bandwidth limit must be positive")
	}
	if opts.days < 0 {
		return fmt.Errorf("days must be positive")
	}
	if opts.identity != "" {
		info, err := os.Stat(opts.identity)
		if err != nil {
			return fmt.Errorf("identity file %q: %w", opts.identity, err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("identity file %q is not a regular file", opts.identity)
		}
	}
	if opts.syncMode {
		if opts.sourceHost == "" || opts.targetHost == "" {
			return fmt.Errorf("--source-host and --target-host are required with --sync")
		}
		if opts.useSCP {
			return fmt.Errorf("--use-scp is not supported with --sync")
		}
		return nil
	}
	if opts.useSCP && opts.exclude != "" {
		return fmt.Errorf("--exclude requires rsync; scp has no safe exclude equivalent")
	}
	if opts.useSCP && opts.limit != 0 {
		return fmt.Errorf("--limit requires rsync")
	}
	if opts.useSCP && opts.resume {
		return fmt.Errorf("--resume requires rsync")
	}
	if !isRemote(opts.source) {
		if _, err := os.Stat(opts.source); err != nil {
			return fmt.Errorf("source %q: %w", opts.source, err)
		}
	}
	if !opts.useSCP && isRemote(opts.source) && isRemote(opts.destination) {
		return fmt.Errorf("rsync cannot copy directly between two remote hosts; use --sync or --use-scp")
	}
	return nil
}
