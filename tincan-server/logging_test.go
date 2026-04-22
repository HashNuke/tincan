package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenLogFileReturnsNilWhenUnset(t *testing.T) {
	logFile, resolvedPath, err := openLogFile("")
	if err != nil {
		t.Fatalf("openLogFile returned error for empty path: %v", err)
	}
	if logFile != nil {
		t.Fatalf("expected nil log file when flag is unset")
	}
	if resolvedPath != "" {
		t.Fatalf("expected empty resolved path, got %q", resolvedPath)
	}
}

func TestOpenLogFileCreatesParentDirectories(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "logs", "tincan-server.log")

	logFile, resolvedPath, err := openLogFile(logPath)
	if err != nil {
		t.Fatalf("openLogFile returned error: %v", err)
	}
	t.Cleanup(func() {
		_ = logFile.Close()
	})

	if resolvedPath != logPath {
		t.Fatalf("expected resolved path %q, got %q", logPath, resolvedPath)
	}
	if _, err := os.Stat(filepath.Dir(logPath)); err != nil {
		t.Fatalf("expected log directory to exist: %v", err)
	}

	if _, err := logFile.WriteString("hello from tincan\n"); err != nil {
		t.Fatalf("write log file: %v", err)
	}
	if err := logFile.Close(); err != nil {
		t.Fatalf("close log file: %v", err)
	}

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	if string(data) != "hello from tincan\n" {
		t.Fatalf("expected log contents to be written, got %q", string(data))
	}
}

func TestOpenLogFileExpandsHomeDirectory(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)

	logFile, resolvedPath, err := openLogFile("~/logs/tincan-server.log")
	if err != nil {
		t.Fatalf("openLogFile returned error: %v", err)
	}
	t.Cleanup(func() {
		_ = logFile.Close()
	})

	expectedPath := filepath.Join(homeDir, "logs", "tincan-server.log")
	if resolvedPath != expectedPath {
		t.Fatalf("expected resolved path %q, got %q", expectedPath, resolvedPath)
	}
}
