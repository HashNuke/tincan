package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	tincanapi "tincan-server/api"
)

type commandHandlers struct {
	run            func(context.Context, []string) error
	setupTailscale func(context.Context, []string) error
}

type runServerOptions struct {
	dataDir         string
	logFile         string
	port            int
	enableTailscale bool
}

func runMainCommand(ctx context.Context, args []string, handlers commandHandlers) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: tincan-server <run|setup-tailscale>")
	}

	switch args[0] {
	case "run":
		if handlers.run == nil {
			handlers.run = runTincanServerCommand
		}
		return handlers.run(ctx, args[1:])
	case "setup-tailscale":
		if handlers.setupTailscale == nil {
			handlers.setupTailscale = runSetupTailscaleCommand
		}
		return handlers.setupTailscale(ctx, args[1:])
	default:
		return fmt.Errorf("unknown command %q\nusage: tincan-server <run|setup-tailscale>", args[0])
	}
}

func runTincanServerCommand(ctx context.Context, args []string) error {
	options, err := parseRunServerOptions(args)
	if err != nil {
		return err
	}

	logFile, resolvedLogFilePath, err := openLogFile(options.logFile)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}

	var runtimeOutput io.Writer
	if logFile != nil {
		defer func() {
			_ = logFile.Close()
		}()
		log.SetOutput(logFile)
		runtimeOutput = logFile
		log.Printf("tincan-server logging to %s", resolvedLogFilePath)
	}

	dataDir, err := resolveDataDir(options.dataDir)
	if err != nil {
		return fmt.Errorf("failed to resolve data dir: %w", err)
	}

	srv, err := newServer(dataDir, options.port, runtimeOutput)
	if err != nil {
		return fmt.Errorf("failed to initialize server: %w", err)
	}
	defer func() {
		if err := srv.conversations.Close(); err != nil {
			log.Printf("failed to close conversation store: %v", err)
		}
	}()
	if err := srv.controlSocket.Start(ctx); err != nil {
		return fmt.Errorf("failed to start control socket: %w", err)
	}
	defer srv.controlSocket.Shutdown()

	if err := srv.speechRuntime.EnsureRunning(ctx); err != nil {
		return fmt.Errorf("failed to start speech services: %w", err)
	}
	defer srv.speechRuntime.Shutdown()

	mux := http.NewServeMux()
	apiAdapters := make(map[string]tincanapi.ModelDiscoveringAdapter, len(srv.agentAdapters))
	for name, adapter := range srv.agentAdapters {
		apiAdapters[name] = adapter
	}
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/hooks/opencode", srv.handleOpenCodeHook)
	tincanapi.Routes{
		AppConfig:     srv.appConfig,
		Profiles:      srv.profiles,
		Backends:      srv.backends,
		Conversations: srv.conversations,
		Adapters:      apiAdapters,
	}.Register(mux)
	mux.Handle("/api/v1/live", srv.liveHub.handler())
	mux.HandleFunc("/session/", srv.handleSessionControl)
	srv.webrtcTransport.RegisterRoutes(mux)

	if options.enableTailscale {
		state, err := startTailscaleRuntime(ctx, mux, tailscaleRuntimeConfig{
			DataDir:    dataDir,
			AppConfig:  srv.appConfig,
			Requested:  true,
			FallbackOn: false,
		})
		srv.setTailscaleRuntimeState(state)
		if err != nil {
			return fmt.Errorf("start tailscale runtime: %w", err)
		}
	} else {
		srv.setTailscaleRuntimeState(tailscaleRuntimeStateFromConfig(srv.appConfig, false))
	}

	addr, localHTTPEnabled := localHTTPAddress(options)
	if !localHTTPEnabled {
		log.Printf("tincan-server %s listening on tailscale port 443", buildVersion)
		<-ctx.Done()
		return nil
	}

	log.Printf("tincan-server %s listening on %s", buildVersion, addr)
	httpServer := &http.Server{Addr: addr, Handler: mux}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("server failed: %w", err)
	}
	return nil
}

func localHTTPAddress(options runServerOptions) (string, bool) {
	if options.enableTailscale {
		return "", false
	}
	return fmt.Sprintf("0.0.0.0:%d", options.port), true
}

func parseRunServerOptions(args []string) (runServerOptions, error) {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	dataDirFlag := flags.String("data-dir", "", "directory for tincan-server runtime data")
	logFileFlag := flags.String("log-file", "", "file path for tincan-server logs")
	portFlag := flags.Int("port", defaultServerPort, "HTTP port for tincan-server")
	tailscaleFlag := flags.Bool("tailscale", false, "enable embedded tailscale phone connectivity")
	if err := flags.Parse(args); err != nil {
		return runServerOptions{}, err
	}

	if *portFlag <= 0 || *portFlag > 65535 {
		return runServerOptions{}, fmt.Errorf("invalid --port: %d", *portFlag)
	}

	return runServerOptions{
		dataDir:         *dataDirFlag,
		logFile:         *logFileFlag,
		port:            *portFlag,
		enableTailscale: *tailscaleFlag,
	}, nil
}
