package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	inferenceProcessShutdownTimeout = 5 * time.Second
	inferenceProcessPollInterval    = 100 * time.Millisecond
)

type inferenceProcessCleaner struct {
	lookupPIDs     func(context.Context, string) ([]int, error)
	signalPID      func(int, syscall.Signal) error
	waitForPIDExit func(context.Context, int, time.Duration) bool
	removeSocket   func(string) error
	currentPID     int
}

func knownInferenceSocketPaths() []string {
	return compactUniquePaths(inferenceSocketPath())
}

func clearExistingInferenceProcesses(ctx context.Context, socketPaths []string) error {
	cleaner := inferenceProcessCleaner{
		lookupPIDs:     lookupPIDsForOpenFile,
		signalPID:      signalProcessID,
		waitForPIDExit: waitForProcessExit,
		removeSocket:   os.Remove,
		currentPID:     os.Getpid(),
	}
	return cleaner.clear(ctx, socketPaths)
}

func (c inferenceProcessCleaner) clear(ctx context.Context, socketPaths []string) error {
	terminatedPIDs := map[int]struct{}{}

	for _, socketPath := range compactUniquePaths(socketPaths...) {
		pids, err := c.lookupPIDs(ctx, socketPath)
		if err != nil {
			return err
		}

		for _, pid := range pids {
			if pid <= 0 || pid == c.currentPID {
				continue
			}
			if _, ok := terminatedPIDs[pid]; ok {
				continue
			}

			if err := c.terminatePID(ctx, pid, socketPath); err != nil {
				return err
			}
			terminatedPIDs[pid] = struct{}{}
		}

		if err := c.removeSocket(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove stale inference socket %s: %w", socketPath, err)
		}
	}

	return nil
}

func (c inferenceProcessCleaner) terminatePID(ctx context.Context, pid int, socketPath string) error {
	log.Printf("terminating existing tincan-inference-macos pid %d for socket %s", pid, socketPath)
	if err := c.signalPID(pid, syscall.SIGTERM); err != nil {
		if isNoSuchProcess(err) {
			return nil
		}
		return fmt.Errorf("terminate existing inference pid %d: %w", pid, err)
	}

	if c.waitForPIDExit(ctx, pid, inferenceProcessShutdownTimeout) {
		return nil
	}

	log.Printf("existing tincan-inference-macos pid %d did not exit after SIGTERM; sending SIGKILL", pid)
	if err := c.signalPID(pid, syscall.SIGKILL); err != nil {
		if isNoSuchProcess(err) {
			return nil
		}
		return fmt.Errorf("force terminate existing inference pid %d: %w", pid, err)
	}
	if c.waitForPIDExit(ctx, pid, inferenceProcessShutdownTimeout) {
		return nil
	}

	return fmt.Errorf("existing inference pid %d did not exit after SIGKILL", pid)
}

func lookupPIDsForOpenFile(ctx context.Context, path string) ([]int, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("stat inference socket %s: %w", path, err)
	}

	command := exec.CommandContext(ctx, lsofExecutable(), "-w", "-t", "--", path)
	output, err := command.CombinedOutput()
	trimmedOutput := strings.TrimSpace(string(output))
	if err != nil && trimmedOutput == "" {
		return nil, nil
	}
	if err != nil {
		if _, statErr := os.Stat(path); errors.Is(statErr, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("list inference socket owner for %s: %w: %s", path, err, trimmedOutput)
	}

	return parseProcessIDs(trimmedOutput)
}

func parseProcessIDs(output string) ([]int, error) {
	pidStrings := strings.Fields(output)
	pids := make([]int, 0, len(pidStrings))
	seen := map[int]struct{}{}

	for _, pidString := range pidStrings {
		pid, err := strconv.Atoi(pidString)
		if err != nil {
			return nil, fmt.Errorf("parse process id %q: %w", pidString, err)
		}
		if _, ok := seen[pid]; ok {
			continue
		}
		pids = append(pids, pid)
		seen[pid] = struct{}{}
	}

	return pids, nil
}

func signalProcessID(pid int, signal syscall.Signal) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(signal)
}

func waitForProcessExit(ctx context.Context, pid int, timeout time.Duration) bool {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()

	ticker := time.NewTicker(inferenceProcessPollInterval)
	defer ticker.Stop()

	for {
		if !processExists(pid) {
			return true
		}

		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return !processExists(pid)
		case <-ticker.C:
		}
	}
}

func processExists(pid int) bool {
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true
	}
	return !errors.Is(err, syscall.ESRCH)
}

func isNoSuchProcess(err error) bool {
	return errors.Is(err, os.ErrProcessDone) ||
		errors.Is(err, syscall.ESRCH) ||
		strings.Contains(strings.ToLower(err.Error()), "no such process")
}

func lsofExecutable() string {
	if fileExists("/usr/sbin/lsof") {
		return "/usr/sbin/lsof"
	}
	return "lsof"
}

func compactUniquePaths(paths ...string) []string {
	result := make([]string, 0, len(paths))
	seen := map[string]struct{}{}
	for _, path := range paths {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		if _, ok := seen[path]; ok {
			continue
		}
		result = append(result, path)
		seen[path] = struct{}{}
	}
	return result
}
