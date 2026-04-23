package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type serverControlSocket struct {
	path         string
	credentials  *serviceCredentialStore
	mu           sync.Mutex
	listener     net.Listener
	shutdownOnce sync.Once
}

type serverControlRequest struct {
	Action string             `json:"action"`
	Data   map[string]*string `json:"data,omitempty"`
}

type serverControlResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

func newServerControlSocket(path string, credentials *serviceCredentialStore) *serverControlSocket {
	return &serverControlSocket{
		path:        path,
		credentials: credentials,
	}
}

func (s *serverControlSocket) Start(ctx context.Context) error {
	if strings.TrimSpace(s.path) == "" {
		return nil
	}

	listener, err := listenOnUnixSocket(s.path)
	if err != nil {
		return err
	}

	s.mu.Lock()
	s.listener = listener
	s.mu.Unlock()

	log.Printf("tincan-server control socket listening on unix://%s", s.path)

	go func() {
		<-ctx.Done()
		s.Shutdown()
	}()
	go s.serve(listener)
	return nil
}

func (s *serverControlSocket) Shutdown() {
	s.shutdownOnce.Do(func() {
		s.mu.Lock()
		listener := s.listener
		s.listener = nil
		s.mu.Unlock()

		if listener != nil {
			_ = listener.Close()
		}
		if strings.TrimSpace(s.path) != "" {
			_ = os.Remove(s.path)
		}
	})
}

func (s *serverControlSocket) serve(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("tincan-server control socket accept failed: %v", err)
			continue
		}

		go s.handleConnection(conn)
	}
}

func (s *serverControlSocket) handleConnection(conn net.Conn) {
	defer conn.Close()

	var request serverControlRequest
	decoder := json.NewDecoder(io.LimitReader(conn, 64<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeServerControlResponse(conn, serverControlResponse{
			OK:    false,
			Error: fmt.Sprintf("decode control request: %v", err),
		})
		return
	}

	if err := s.applyRequest(request); err != nil {
		writeServerControlResponse(conn, serverControlResponse{
			OK:    false,
			Error: err.Error(),
		})
		return
	}

	writeServerControlResponse(conn, serverControlResponse{OK: true})
}

func (s *serverControlSocket) applyRequest(request serverControlRequest) error {
	switch strings.TrimSpace(request.Action) {
	case "secrets":
		if s.credentials == nil {
			return errors.New("credential store is unavailable")
		}
		return s.credentials.ApplySecretUpdates(request.Data)
	default:
		return fmt.Errorf("unsupported control action %q", request.Action)
	}
}

func writeServerControlResponse(writer io.Writer, response serverControlResponse) {
	if err := json.NewEncoder(writer).Encode(response); err != nil {
		log.Printf("write control socket response failed: %v", err)
	}
}

func listenOnUnixSocket(path string) (net.Listener, error) {
	if path == "" {
		return nil, fmt.Errorf("unix socket path is empty")
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create control socket directory: %w", err)
	}

	if err := removeStaleUnixSocket(path); err != nil {
		return nil, err
	}

	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen on control socket %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(path)
		return nil, fmt.Errorf("restrict control socket permissions: %w", err)
	}
	return listener, nil
}

func removeStaleUnixSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("inspect control socket path %s: %w", path, err)
	}

	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("control socket path %s exists and is not a socket", path)
	}

	if isUnixSocketReady(path) {
		return fmt.Errorf("control socket path %s is already in use", path)
	}

	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale control socket %s: %w", path, err)
	}
	return nil
}

func isUnixSocketReady(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}

	conn, err := net.DialTimeout("unix", path, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
