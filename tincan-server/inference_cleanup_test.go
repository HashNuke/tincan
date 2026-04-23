package main

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestInferenceProcessCleanerTerminatesSocketOwnersAndRemovesSockets(t *testing.T) {
	socketPIDs := map[string][]int{
		"/tmp/tincan-inference-macos.sock": {100, 42, 100},
	}
	var lookups []string
	var signals []string
	var removed []string

	cleaner := inferenceProcessCleaner{
		lookupPIDs: func(_ context.Context, socketPath string) ([]int, error) {
			lookups = append(lookups, socketPath)
			return socketPIDs[socketPath], nil
		},
		signalPID: func(pid int, signal syscall.Signal) error {
			signals = append(signals, fmt.Sprintf("%d:%d", pid, signal))
			return nil
		},
		waitForPIDExit: func(_ context.Context, _ int, _ time.Duration) bool {
			return true
		},
		removeSocket: func(socketPath string) error {
			removed = append(removed, socketPath)
			return nil
		},
		currentPID: 42,
	}

	err := cleaner.clear(context.Background(), []string{
		"/tmp/tincan-inference-macos.sock",
		"/tmp/tincan-inference-macos.sock",
		"",
	})
	if err != nil {
		t.Fatalf("clear returned error: %v", err)
	}

	expectedLookups := []string{"/tmp/tincan-inference-macos.sock"}
	if !slices.Equal(lookups, expectedLookups) {
		t.Fatalf("expected lookups %v, got %v", expectedLookups, lookups)
	}

	expectedSignals := []string{
		fmt.Sprintf("100:%d", syscall.SIGTERM),
	}
	if !slices.Equal(signals, expectedSignals) {
		t.Fatalf("expected signals %v, got %v", expectedSignals, signals)
	}

	if !slices.Equal(removed, expectedLookups) {
		t.Fatalf("expected removed sockets %v, got %v", expectedLookups, removed)
	}
}

func TestInferenceProcessCleanerEscalatesWhenProcessDoesNotExit(t *testing.T) {
	var signals []syscall.Signal
	waitCalls := 0
	cleaner := inferenceProcessCleaner{
		lookupPIDs: func(context.Context, string) ([]int, error) {
			return []int{100}, nil
		},
		signalPID: func(_ int, signal syscall.Signal) error {
			signals = append(signals, signal)
			return nil
		},
		waitForPIDExit: func(context.Context, int, time.Duration) bool {
			waitCalls += 1
			return waitCalls == 2
		},
		removeSocket: func(string) error {
			return nil
		},
		currentPID: 42,
	}

	err := cleaner.clear(context.Background(), []string{"/tmp/tincan-inference-macos.sock"})
	if err != nil {
		t.Fatalf("clear returned error: %v", err)
	}

	expectedSignals := []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL}
	if !slices.Equal(signals, expectedSignals) {
		t.Fatalf("expected signals %v, got %v", expectedSignals, signals)
	}
}

func TestInferenceProcessCleanerIgnoresMissingSocketOnRemove(t *testing.T) {
	cleaner := inferenceProcessCleaner{
		lookupPIDs: func(context.Context, string) ([]int, error) {
			return nil, nil
		},
		signalPID: func(int, syscall.Signal) error {
			t.Fatal("signalPID should not be called")
			return nil
		},
		waitForPIDExit: func(context.Context, int, time.Duration) bool {
			t.Fatal("waitForPIDExit should not be called")
			return false
		},
		removeSocket: func(string) error {
			return os.ErrNotExist
		},
		currentPID: 42,
	}

	if err := cleaner.clear(context.Background(), []string{"/tmp/tincan-inference-macos.sock"}); err != nil {
		t.Fatalf("expected missing socket removal to be ignored, got %v", err)
	}
}

func TestParseProcessIDs(t *testing.T) {
	got, err := parseProcessIDs("100\n200\n100\n")
	if err != nil {
		t.Fatalf("parseProcessIDs returned error: %v", err)
	}

	expected := []int{100, 200}
	if !slices.Equal(got, expected) {
		t.Fatalf("expected pids %v, got %v", expected, got)
	}
}

func TestParseProcessIDsRejectsNonNumericOutput(t *testing.T) {
	_, err := parseProcessIDs("100\nnot-a-pid\n")
	if err == nil {
		t.Fatal("expected parseProcessIDs to reject non-numeric output")
	}
	if !strings.Contains(err.Error(), "not-a-pid") {
		t.Fatalf("expected error to name invalid pid, got %v", err)
	}
}
