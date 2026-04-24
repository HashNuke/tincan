package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	tincanconfig "tincan-server/config"

	"tailscale.com/tsnet"
)

func runSetupTailscaleCommand(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("setup-tailscale", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	dataDirFlag := flags.String("data-dir", "", "directory for tincan-server runtime data")
	if err := flags.Parse(args); err != nil {
		return err
	}

	if err := setupTailscale(ctx, *dataDirFlag); err != nil {
		emitTailscaleMarker("TINCAN_TAILSCALE_ERROR", err.Error())
		return err
	}
	return nil
}

func setupTailscale(ctx context.Context, dataDirFlag string) error {
	dataDir, err := resolveDataDir(dataDirFlag)
	if err != nil {
		return fmt.Errorf("resolve data dir: %w", err)
	}

	hostname, err := derivedTailscaleHostname()
	if err != nil {
		return fmt.Errorf("resolve tailscale hostname: %w", err)
	}

	emitTailscaleMarker("TINCAN_TAILSCALE_STATUS", "starting")

	stateDir := filepath.Join(dataDir, "tsnet")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return fmt.Errorf("create tailscale state directory: %w", err)
	}

	tsServer := &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		UserLogf: emitTailscaleUserLogf,
		Logf:     func(string, ...any) {},
	}
	defer tsServer.Close()

	ln, err := tsServer.Listen("tcp", ":80")
	if err != nil {
		return fmt.Errorf("start tailscale setup listener: %w", err)
	}
	defer ln.Close()
	_ = ctx

	nodeURL, err := waitForTailscaleNodeURL(ctx, tsServer, 500*time.Millisecond)
	if err != nil {
		return err
	}

	appConfig, err := tincanconfig.NewAppConfigStore(dataDir)
	if err != nil {
		return fmt.Errorf("open app config: %w", err)
	}
	if err := appConfig.SetTailscaleBootstrapResult(nodeURL); err != nil {
		return fmt.Errorf("persist tailscale setup result: %w", err)
	}

	emitTailscaleMarker("TINCAN_TAILSCALE_STATUS", "running")
	emitTailscaleMarker("TINCAN_TAILSCALE_NODE", nodeURL)
	log.Printf("tailscale setup complete for hostname %q", hostname)
	return nil
}

func emitTailscaleUserLogf(format string, args ...any) {
	message := fmt.Sprintf(format, args...)
	log.Print(message)
	authURL := tailscaleAuthURLPattern.FindString(message)
	if authURL == "" {
		return
	}
	emitTailscaleMarker("TINCAN_TAILSCALE_STATUS", "needs_login")
	emitTailscaleMarker("TINCAN_TAILSCALE_AUTH_URL", authURL)
}

func emitTailscaleMarker(key, value string) {
	fmt.Printf("%s=%s\n", key, value)
}

type tailscaleCertDomainProvider interface {
	CertDomains() []string
}

func waitForTailscaleNodeURL(
	ctx context.Context,
	provider tailscaleCertDomainProvider,
	interval time.Duration,
) (string, error) {
	if interval <= 0 {
		interval = 500 * time.Millisecond
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		if nodeURL, err := selectTailscaleNodeURL(provider.CertDomains()); err == nil {
			return nodeURL, nil
		}

		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ticker.C:
		}
	}
}
