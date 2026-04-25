package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tincanconfig "tincan-server/config"

	"tailscale.com/tsnet"
)

const tailscaleFallbackMessage = "Could not start with Tailscale. Please ensure Tailscale is running."

var tailscaleAuthURLPattern = regexp.MustCompile(`https://login\.tailscale\.com/a/\S+`)

type tailscaleRuntimeState struct {
	Configured bool
	Active     bool
	NodeURL    string
	Message    string
}

type tailscaleRuntimeConfig struct {
	DataDir    string
	AppConfig  *tincanconfig.AppConfigStore
	Requested  bool
	FallbackOn bool
}

func tailscaleRuntimeStateFromConfig(appConfig *tincanconfig.AppConfigStore, active bool) tailscaleRuntimeState {
	state := tailscaleRuntimeState{Active: active}
	if appConfig == nil {
		return state
	}
	state.Configured = appConfig.TailscaleEnabled()
	if nodeURL, ok := appConfig.TailscaleNodeURL(); ok {
		state.NodeURL = nodeURL
	}
	return state
}

func startTailscaleRuntime(ctx context.Context, mux *http.ServeMux, config tailscaleRuntimeConfig) (tailscaleRuntimeState, error) {
	state := tailscaleRuntimeStateFromConfig(config.AppConfig, false)
	if !config.Requested {
		return state, nil
	}
	state.Configured = true

	tsServer, ln, nodeURL, err := prepareTailscaleRuntime(ctx, config)
	if err != nil {
		state.Active = false
		state.Message = tailscaleFallbackMessage
		if !config.FallbackOn {
			return state, err
		}
		return state, nil
	}

	state.Active = true
	state.Message = ""
	state.NodeURL = nodeURL
	if config.AppConfig != nil && nodeURL != "" {
		if current, ok := config.AppConfig.TailscaleNodeURL(); !ok || current != nodeURL {
			if err := config.AppConfig.SetTailscaleNodeURL(nodeURL); err != nil {
				_ = ln.Close()
				_ = tsServer.Close()
				return state, fmt.Errorf("persist tailscale node url: %w", err)
			}
		}
	}

	httpServer := &http.Server{Handler: mux}
	go func() {
		defer tsServer.Close()
		defer ln.Close()

		go func() {
			<-ctx.Done()
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = httpServer.Shutdown(shutdownCtx)
		}()

		if err := httpServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("tailscale runtime stopped: %v", err)
		}
	}()

	return state, nil
}

func prepareTailscaleRuntime(ctx context.Context, config tailscaleRuntimeConfig) (*tsnet.Server, net.Listener, string, error) {
	hostname, err := derivedTailscaleHostname()
	if err != nil {
		return nil, nil, "", fmt.Errorf("resolve tailscale hostname: %w", err)
	}

	stateDir := filepath.Join(config.DataDir, "tsnet")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, nil, "", fmt.Errorf("create tailscale state directory: %w", err)
	}

	tsServer := &tsnet.Server{
		Dir:      stateDir,
		Hostname: hostname,
		UserLogf: func(format string, args ...any) {
			log.Printf(format, args...)
		},
		Logf: func(string, ...any) {},
	}

	ln, err := tsServer.Listen("tcp", ":443")
	if err != nil {
		_ = tsServer.Close()
		return nil, nil, "", err
	}

	lc, err := tsServer.LocalClient()
	if err != nil {
		_ = ln.Close()
		_ = tsServer.Close()
		return nil, nil, "", err
	}

	nodeURL, err := runtimeTailscaleNodeURL(ctx, tsServer)
	if err != nil {
		_ = ln.Close()
		_ = tsServer.Close()
		return nil, nil, "", err
	}

	wrapped := tls.NewListener(ln, &tls.Config{GetCertificate: lc.GetCertificate})
	return tsServer, wrapped, nodeURL, nil
}

func runtimeTailscaleNodeURL(ctx context.Context, provider tailscaleCertDomainProvider) (string, error) {
	return waitForTailscaleNodeURL(ctx, provider, 500*time.Millisecond)
}

func derivedTailscaleHostname() (string, error) {
	hostname, err := os.Hostname()
	if err != nil {
		return "", err
	}
	return normalizeTailscaleHostname(hostname), nil
}

func normalizeTailscaleHostname(hostname string) string {
	cleaned := strings.ToLower(strings.TrimSpace(hostname))
	cleaned = strings.ReplaceAll(cleaned, "'", "")
	cleaned = strings.ReplaceAll(cleaned, "’", "")

	var builder strings.Builder
	lastWasHyphen := false
	for _, r := range cleaned {
		isAlphaNumeric := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if isAlphaNumeric {
			builder.WriteRune(r)
			lastWasHyphen = false
			continue
		}
		if !lastWasHyphen {
			builder.WriteRune('-')
			lastWasHyphen = true
		}
	}

	servicePart := strings.Trim(builder.String(), "-")
	if servicePart == "" {
		servicePart = "mac"
	}

	return "tincan-" + servicePart
}

func firstNonEmptyString(groups ...[]string) string {
	for _, group := range groups {
		for _, item := range group {
			trimmed := strings.TrimSpace(item)
			if trimmed != "" {
				return trimmed
			}
		}
	}
	return ""
}

func selectTailscaleNodeURL(groups ...[]string) (string, error) {
	for _, group := range groups {
		for _, item := range group {
			host := strings.TrimSpace(item)
			host = strings.TrimSuffix(host, ".")
			if host == "" {
				continue
			}
			if !strings.Contains(host, ".ts.net") {
				continue
			}
			return "https://" + host, nil
		}
	}
	return "", fmt.Errorf("no .ts.net Tailscale domain found")
}
