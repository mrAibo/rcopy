// rcopy is a small command-line front end for safe local and remote file copies.
// Copyright (C) 2025-2026 Aleksej V
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
)

var version = "dev"

type application struct {
	in     io.Reader
	out    io.Writer
	errOut io.Writer
	color  bool
}

type command struct {
	name string
	args []string
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	app := application{
		in:     os.Stdin,
		out:    os.Stdout,
		errOut: os.Stderr,
		color:  os.Getenv("NO_COLOR") == "" && isTerminal(os.Stdout),
	}

	if err := app.run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(app.errOut, app.red("Error:"), err)
		os.Exit(1)
	}
}

func (a *application) run(ctx context.Context, args []string) error {
	opts, err := parseOptions(args)
	if err != nil {
		return err
	}
	if opts.showHelp {
		fmt.Fprint(a.out, helpText())
		return nil
	}
	if opts.showVersion {
		fmt.Fprintf(a.out, "rcopy %s\n", version)
		return nil
	}

	if opts.logFile != "" {
		file, err := os.OpenFile(opts.logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return fmt.Errorf("open log file %q: %w", opts.logFile, err)
		}
		defer file.Close()
		a.out = io.MultiWriter(a.out, file)
		a.errOut = io.MultiWriter(a.errOut, file)
	}

	if err := validateOptions(opts); err != nil {
		return err
	}
	if opts.syncMode {
		return a.runSync(ctx, opts)
	}
	return a.runCopy(ctx, opts)
}
