package main

import (
	"context"
	"strings"
	"testing"
)

func TestRunMainCommandRequiresSubcommand(t *testing.T) {
	err := runMainCommand(context.Background(), nil, commandHandlers{})
	if err == nil || !strings.Contains(err.Error(), "usage: tincan-server <run|setup-tailscale>") {
		t.Fatalf("expected usage error for missing subcommand, got %v", err)
	}
}

func TestRunMainCommandRejectsUnknownSubcommand(t *testing.T) {
	err := runMainCommand(context.Background(), []string{"unknown"}, commandHandlers{})
	if err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("expected unknown command error, got %v", err)
	}
}

func TestRunMainCommandRejectsTopLevelFlags(t *testing.T) {
	err := runMainCommand(context.Background(), []string{"--data-dir", "/tmp/tincan"}, commandHandlers{})
	if err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("expected top-level flag to be rejected without run subcommand, got %v", err)
	}
}

func TestRunMainCommandDispatchesRun(t *testing.T) {
	called := false
	err := runMainCommand(context.Background(), []string{"run", "--tailscale"}, commandHandlers{
		run: func(_ context.Context, args []string) error {
			called = true
			if len(args) != 1 || args[0] != "--tailscale" {
				t.Fatalf("unexpected args: %#v", args)
			}
			return nil
		},
	})
	if err != nil {
		t.Fatalf("runMainCommand returned error: %v", err)
	}
	if !called {
		t.Fatalf("expected run handler to be called")
	}
}

func TestRunMainCommandDispatchesSetupTailscale(t *testing.T) {
	called := false
	err := runMainCommand(context.Background(), []string{"setup-tailscale", "--data-dir", "/tmp/tincan"}, commandHandlers{
		setupTailscale: func(_ context.Context, args []string) error {
			called = true
			if len(args) != 2 || args[0] != "--data-dir" || args[1] != "/tmp/tincan" {
				t.Fatalf("unexpected args: %#v", args)
			}
			return nil
		},
	})
	if err != nil {
		t.Fatalf("runMainCommand returned error: %v", err)
	}
	if !called {
		t.Fatalf("expected setup-tailscale handler to be called")
	}
}

func TestParseRunServerOptionsAcceptsBareServerOptions(t *testing.T) {
	options, err := parseRunServerOptions([]string{
		"--data-dir", "/tmp/tincan-data",
		"--log-file", "/tmp/tincan.log",
		"--port", "5490",
	})
	if err != nil {
		t.Fatalf("parseRunServerOptions returned error: %v", err)
	}

	if options.dataDir != "/tmp/tincan-data" {
		t.Fatalf("unexpected data dir: %q", options.dataDir)
	}
	if options.logFile != "/tmp/tincan.log" {
		t.Fatalf("unexpected log file: %q", options.logFile)
	}
	if options.port != 5490 {
		t.Fatalf("unexpected port: %d", options.port)
	}
	if options.enableTailscale {
		t.Fatalf("did not expect tailscale to be enabled")
	}
}

func TestParseRunServerOptionsAcceptsTailscaleFlag(t *testing.T) {
	options, err := parseRunServerOptions([]string{"--tailscale"})
	if err != nil {
		t.Fatalf("parseRunServerOptions returned error: %v", err)
	}

	if !options.enableTailscale {
		t.Fatalf("expected tailscale to be enabled")
	}
}

func TestParseRunServerOptionsRejectsInvalidPort(t *testing.T) {
	err := func() error {
		_, err := parseRunServerOptions([]string{"--port", "70000"})
		return err
	}()
	if err == nil || !strings.Contains(err.Error(), "invalid --port") {
		t.Fatalf("expected invalid port error, got %v", err)
	}
}

func TestLocalHTTPAddressUsesRunPortWithoutTailscale(t *testing.T) {
	address, ok := localHTTPAddress(runServerOptions{port: 4990})
	if !ok {
		t.Fatalf("expected local HTTP listener to be enabled")
	}
	if address != "0.0.0.0:4990" {
		t.Fatalf("unexpected local HTTP address: %q", address)
	}
}

func TestLocalHTTPAddressIsDisabledWithTailscale(t *testing.T) {
	address, ok := localHTTPAddress(runServerOptions{port: 4990, enableTailscale: true})
	if ok {
		t.Fatalf("expected local HTTP listener to be disabled under tailscale, got %q", address)
	}
}
