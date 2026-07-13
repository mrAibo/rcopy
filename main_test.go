package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseOptionsKeepsCompatibleFlags(t *testing.T) {
	opts, err := parseOptions([]string{"-q", "-m", "-u", "alice", "-p", "2222", "-l", "1024", "src", "host:/dst"})
	if err != nil {
		t.Fatal(err)
	}
	if !opts.compress || !opts.verbose || !opts.move {
		t.Fatalf("quick/move flags not applied: %+v", opts)
	}
	if opts.user != "alice" || opts.port != 2222 || opts.limit != 1024 {
		t.Fatalf("option values not parsed: %+v", opts)
	}
}

func TestBuildRsyncMoveDoesNotDeleteExcludedFilesBlindly(t *testing.T) {
	opts := options{move: true, exclude: "*.log", compress: true, resume: true, limit: 2048}
	cmd := buildCopyCommand(opts, "src", "host:/dst")
	want := []string{"-a", "-h", "--info=progress2", "-z", "--partial", "--append-verify", "--remove-source-files", "--bwlimit=2048", "--exclude=*.log", "src", "host:/dst"}
	if !reflect.DeepEqual(cmd.args, want) {
		t.Fatalf("unexpected rsync args:\n got: %#v\nwant: %#v", cmd.args, want)
	}
}

func TestSCPUsesUppercasePortFlag(t *testing.T) {
	cmd := buildCopyCommand(options{useSCP: true, port: 2222, identity: "/tmp/key"}, "src", "host:/dst")
	got := strings.Join(cmd.args, " ")
	if !strings.Contains(got, "-P 2222") {
		t.Fatalf("scp port must use -P, got %q", got)
	}
	if strings.Contains(got, "-p 2222") {
		t.Fatalf("scp command contains incorrect lowercase port flag: %q", got)
	}
}

func TestExcludeFileUsesRsyncExcludeFrom(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "exclude.txt")
	if err := os.WriteFile(file, []byte("*.log\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := buildCopyCommand(options{exclude: file}, "src", "dst")
	if !contains(cmd.args, "--exclude-from="+file) {
		t.Fatalf("exclude file was not passed with --exclude-from: %#v", cmd.args)
	}
}

func TestWithUserPreservesExplicitRemoteUser(t *testing.T) {
	if got := withUser("root@example:/tmp", "alice"); got != "root@example:/tmp" {
		t.Fatalf("explicit user changed to %q", got)
	}
	if got := withUser("example:/tmp", "alice"); got != "alice@example:/tmp" {
		t.Fatalf("user not applied: %q", got)
	}
}

func TestRemoteIPv6Parsing(t *testing.T) {
	host, path, ok := splitRemote("[2001:db8::1]:/data")
	if !ok || host != "[2001:db8::1]" || path != "/data" {
		t.Fatalf("unexpected parse: host=%q path=%q ok=%v", host, path, ok)
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestOptionsMayFollowPositionalArguments(t *testing.T) {
	opts, err := parseOptions([]string{"source", "host:/dest", "--verbose", "--port", "2222"})
	if err != nil {
		t.Fatal(err)
	}
	if !opts.verbose || opts.port != 2222 || opts.source != "source" || opts.destination != "host:/dest" {
		t.Fatalf("interspersed options not preserved: %+v", opts)
	}
}

func TestRemoteIPv6WithUserParsing(t *testing.T) {
	host, path, ok := splitRemote("alice@[2001:db8::1]:/data")
	if !ok || host != "alice@[2001:db8::1]" || path != "/data" {
		t.Fatalf("unexpected parse: host=%q path=%q ok=%v", host, path, ok)
	}
}

func TestRemoteHomePathKeepsExpansion(t *testing.T) {
	if got := remoteShellPath("~/data files"); got != `"$HOME"/'data files'` {
		t.Fatalf("unexpected remote path: %q", got)
	}
}
