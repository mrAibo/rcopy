package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

func (a *application) runCopy(ctx context.Context, opts options) error {
	source := withUser(opts.source, opts.user)
	destination := withUser(opts.destination, opts.user)
	cmd := buildCopyCommand(opts, source, destination)

	a.printSummary(opts, source, destination, commandString(cmd))
	if opts.dryRun {
		fmt.Fprintln(a.out, a.yellow("DRY RUN: no changes were made"))
		return nil
	}
	if opts.move && !opts.force {
		ok, err := a.confirm("Move mode deletes successfully transferred source files. Continue? [y/N] ")
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("operation cancelled")
		}
	}
	if err := requireCommands(cmd.name); err != nil {
		return err
	}

	fmt.Fprintln(a.out, a.yellow("Transferring..."))
	if err := a.execute(ctx, nil, cmd); err != nil {
		return fmt.Errorf("transfer failed: %w", err)
	}
	if opts.move && opts.useSCP {
		if err := a.removeSCPSource(ctx, opts, source); err != nil {
			return fmt.Errorf("transfer succeeded but source removal failed: %w", err)
		}
	}
	fmt.Fprintln(a.out, a.green("Transfer completed successfully"))
	return nil
}

func buildCopyCommand(opts options, source, destination string) command {
	if opts.useSCP {
		args := []string{"-r"}
		if opts.verbose {
			args = append(args, "-v")
		}
		if opts.compress {
			args = append(args, "-C")
		}
		if opts.port != 0 {
			args = append(args, "-P", strconv.Itoa(opts.port))
		}
		if opts.identity != "" {
			args = append(args, "-i", opts.identity)
		}
		return command{name: "scp", args: append(args, source, destination)}
	}

	args := []string{"-a", "-h", "--info=progress2"}
	if opts.verbose {
		args = append(args, "-v", "--stats")
	}
	if opts.compress {
		args = append(args, "-z")
	}
	if opts.resume {
		args = append(args, "--partial", "--append-verify")
	}
	if opts.move {
		// rsync only removes files after they have transferred successfully. Excluded
		// files remain in place, avoiding the data loss possible with rm -rf.
		args = append(args, "--remove-source-files")
	}
	if opts.limit != 0 {
		args = append(args, "--bwlimit="+strconv.Itoa(opts.limit))
	}
	if opts.exclude != "" {
		if info, err := os.Stat(opts.exclude); err == nil && info.Mode().IsRegular() {
			args = append(args, "--exclude-from="+opts.exclude)
		} else {
			args = append(args, "--exclude="+opts.exclude)
		}
	}
	if remoteTransfer(source, destination) && (opts.port != 0 || opts.identity != "") {
		args = append(args, "-e", sshTransport(opts))
	}
	return command{name: "rsync", args: append(args, source, destination)}
}

func (a *application) runSync(ctx context.Context, opts options) error {
	sourceHost := addUserToHost(opts.sourceHost, opts.user)
	targetHost := addUserToHost(opts.targetHost, opts.user)
	findRemote := "cd -- " + remoteShellPath(opts.source) + " && find . -type f"
	if opts.days != 0 {
		findRemote += " -mtime -" + strconv.Itoa(opts.days)
	}
	findRemote += " -print0"

	findCmd := command{name: "ssh", args: append(sshArgs(opts, sourceHost), findRemote)}
	fromSource := buildSyncRsync(opts, sourceHost+":"+trailingSlash(opts.source), "STAGING/", "FILES")
	toTarget := buildSyncRsync(opts, "STAGING/", targetHost+":"+trailingSlash(opts.destination), "FILES")

	a.printSyncSummary(opts, sourceHost, targetHost, []command{findCmd, fromSource, toTarget})
	if opts.dryRun {
		fmt.Fprintln(a.out, a.yellow("DRY RUN: no changes were made"))
		return nil
	}
	if opts.move && !opts.force {
		ok, err := a.confirm("Sync move mode deletes source files after both copy stages succeed. Continue? [y/N] ")
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("operation cancelled")
		}
	}
	if err := requireCommands("ssh", "rsync"); err != nil {
		return err
	}

	tempDir, err := os.MkdirTemp("", "rcopy-sync-")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	defer os.RemoveAll(tempDir)
	listPath := filepath.Join(tempDir, "files.list")
	listFile, err := os.OpenFile(listPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create file list: %w", err)
	}
	fmt.Fprintln(a.out, a.yellow("Collecting source file list..."))
	err = a.executeTo(ctx, nil, listFile, findCmd)
	closeErr := listFile.Close()
	if err != nil {
		return fmt.Errorf("collect source file list: %w", err)
	}
	if closeErr != nil {
		return fmt.Errorf("close source file list: %w", closeErr)
	}
	info, err := os.Stat(listPath)
	if err != nil {
		return fmt.Errorf("inspect source file list: %w", err)
	}
	if info.Size() == 0 {
		fmt.Fprintln(a.out, a.yellow("No matching files found"))
		return nil
	}

	staging := trailingSlash(tempDir)
	fromSource = buildSyncRsync(opts, sourceHost+":"+trailingSlash(opts.source), staging, listPath)
	toTarget = buildSyncRsync(opts, staging, targetHost+":"+trailingSlash(opts.destination), listPath)

	fmt.Fprintln(a.out, a.yellow("Copying from source host to local staging..."))
	if err := a.execute(ctx, nil, fromSource); err != nil {
		return fmt.Errorf("copy from source host: %w", err)
	}
	fmt.Fprintln(a.out, a.yellow("Copying from local staging to target host..."))
	if err := a.execute(ctx, nil, toTarget); err != nil {
		return fmt.Errorf("copy to target host: %w", err)
	}
	if opts.move {
		file, err := os.Open(listPath)
		if err != nil {
			return fmt.Errorf("open source file list for removal: %w", err)
		}
		defer file.Close()
		removeRemote := "cd -- " + remoteShellPath(opts.source) + " && xargs -0 -r rm -f --"
		removeCmd := command{name: "ssh", args: append(sshArgs(opts, sourceHost), removeRemote)}
		fmt.Fprintln(a.out, a.yellow("Removing transferred files from source host..."))
		if err := a.execute(ctx, file, removeCmd); err != nil {
			return fmt.Errorf("target copy succeeded but source removal failed: %w", err)
		}
	}
	fmt.Fprintln(a.out, a.green("Sync completed successfully"))
	return nil
}

func buildSyncRsync(opts options, source, destination, listPath string) command {
	args := []string{"-a", "-z", "--from0", "--files-from=" + listPath, "-e", sshTransport(opts)}
	if opts.verbose {
		args = append(args, "-v", "--stats", "--info=progress2")
	}
	if opts.resume {
		args = append(args, "--partial", "--append-verify")
	}
	if opts.limit != 0 {
		args = append(args, "--bwlimit="+strconv.Itoa(opts.limit))
	}
	if opts.exclude != "" {
		if info, err := os.Stat(opts.exclude); err == nil && info.Mode().IsRegular() {
			args = append(args, "--exclude-from="+opts.exclude)
		} else {
			args = append(args, "--exclude="+opts.exclude)
		}
	}
	return command{name: "rsync", args: append(args, source, destination)}
}

func (a *application) removeSCPSource(ctx context.Context, opts options, source string) error {
	if !isRemote(source) {
		return os.RemoveAll(source)
	}
	host, path, ok := splitRemote(source)
	if !ok || path == "" || path == "/" {
		return fmt.Errorf("refusing to remove unsafe remote source %q", source)
	}
	removeCmd := command{name: "ssh", args: append(sshArgs(opts, host), "rm -rf -- "+remoteShellPath(path))}
	return a.execute(ctx, nil, removeCmd)
}
