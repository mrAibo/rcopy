package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseArgsPreservesCompatibleOptions(t *testing.T) {
	opts, help, err := parseArgs([]string{"-q", "-m", "-p", "2222", "-i", "/tmp/key", "-l", "1024", "-e", "*.log", "source", "host:/dest"})
	if err != nil {
		t.Fatal(err)
	}
	if help {
		t.Fatal("unexpected help")
	}
	if !opts.compress || !opts.verbose || !opts.move {
		t.Fatalf("quick/move flags not preserved: %+v", opts)
	}
	if opts.port != "2222" || opts.identity != "/tmp/key" || opts.limit != "1024" || opts.exclude != "*.log" {
		t.Fatalf("option values not preserved: %+v", opts)
	}
	if opts.source != "source" || opts.dest != "host:/dest" {
		t.Fatalf("positional arguments not preserved: %+v", opts)
	}
}

func TestBuildRsyncCommandUsesArgumentBoundaries(t *testing.T) {
	temp := t.TempDir()
	exclude := filepath.Join(temp, "exclude patterns")
	if err := os.WriteFile(exclude, []byte("*.log\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	opts := options{
		source:   "source with spaces",
		dest:     "host:/target path",
		port:     "2222",
		identity: "/keys/private key",
		limit:    "1024",
		exclude:  exclude,
		resume:   true,
	}
	cmd, err := buildTransferCommand(opts)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"-avh", "--info=progress2", "--partial", "--append-verify", "--bwlimit=1024",
		"--exclude-from=" + exclude, "-e", "ssh -p 2222 -i /keys/private key",
		"source with spaces", "host:/target path",
	}
	if cmd.name != "rsync" || !reflect.DeepEqual(cmd.args, want) {
		t.Fatalf("command mismatch\n got: %q %q\nwant: %q %q", cmd.name, cmd.args, "rsync", want)
	}
}

func TestBuildSCPCommandUsesUppercasePortFlag(t *testing.T) {
	cmd, err := buildTransferCommand(options{source: "a", dest: "host:b", useSCP: true, port: "2222"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-r", "-P", "2222", "a", "host:b"}
	if !reflect.DeepEqual(cmd.args, want) {
		t.Fatalf("got %q, want %q", cmd.args, want)
	}
}

func TestApplyUserOnlyChangesRemotePathsWithoutUser(t *testing.T) {
	cases := map[string]string{
		"host:/path":      "alice@host:/path",
		"bob@host:/path":  "bob@host:/path",
		"/local/path":     "/local/path",
		"relative/path":   "relative/path",
		"C:\\local\\path": "C:\\local\\path",
	}
	for input, want := range cases {
		if got := applyUser(input, "alice"); got != want {
			t.Errorf("applyUser(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestShellQuoteHandlesSingleQuote(t *testing.T) {
	got := shellQuote("a'b")
	if got != "'a'\\''b'" {
		t.Fatalf("unexpected quote: %s", got)
	}
}

func TestRunRejectsUnknownOption(t *testing.T) {
	var stdout, stderr strings.Builder
	code := run([]string{"--unknown", "a", "b"}, strings.NewReader(""), &stdout, &stderr)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "unknown option") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}
