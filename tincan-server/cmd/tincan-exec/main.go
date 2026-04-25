package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

var buildVersion = "dev"

func main() {
	_ = os.Unsetenv("__CF_USER_TEXT_ENCODING")

	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tincan-exec <command> [args...]")
		os.Exit(2)
	}

	command := exec.Command(os.Args[1], os.Args[2:]...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = os.Environ()

	signals := make(chan os.Signal, 8)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	defer signal.Stop(signals)

	if err := command.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "start child command: %v\n", err)
		os.Exit(1)
	}

	go func() {
		for sig := range signals {
			if command.Process != nil {
				_ = command.Process.Signal(sig)
			}
		}
	}()

	if err := command.Wait(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "wait child command: %v\n", err)
		os.Exit(1)
	}
}
