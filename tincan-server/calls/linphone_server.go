package calls

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
)

type LinphoneServer struct {
	manager *Manager
}

func NewLinphoneServer(manager *Manager) (*LinphoneServer, error) {
	return &LinphoneServer{
		manager: manager,
	}, nil
}

func (s *LinphoneServer) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/linphone/session", s.handleRegisterSession)
	mux.HandleFunc("/linphone/session/", s.handleSessionSubpath)
}

// POST /linphone/session — register a new call session, returns {"session_id":"..."}
func (s *LinphoneServer) handleRegisterSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sessionID := uuid.NewString()
	s.manager.RegisterSession(sessionID)
	log.Printf("linphone: registered session %s", sessionID)
	writeLinphoneJSON(w, http.StatusOK, map[string]string{"session_id": sessionID})
}

// DELETE /linphone/session/{id}    — remove a session
// GET    /linphone/session/{id}/events — SSE event stream
func (s *LinphoneServer) handleSessionSubpath(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/linphone/session/")
	parts := strings.SplitN(rest, "/", 2)
	sessionID := parts[0]
	if sessionID == "" {
		http.NotFound(w, r)
		return
	}

	if len(parts) == 1 {
		if r.Method != http.MethodDelete {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		s.manager.RemoveSession(sessionID)
		log.Printf("linphone: removed session %s", sessionID)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if parts[1] != "events" || r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}

	if !s.manager.HasSession(sessionID) {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}

	s.serveSSE(w, r, sessionID)
}

func (s *LinphoneServer) serveSSE(w http.ResponseWriter, r *http.Request, sessionID string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	sink := newSSEEventSink()
	if !s.manager.SetEventSink(sessionID, sink) {
		log.Printf("linphone: SSE SetEventSink failed for %s", sessionID)
		return
	}
	defer func() {
		sink.close()
		s.manager.SetEventSink(sessionID, nil)
	}()

	log.Printf("linphone: SSE stream open for session %s", sessionID)

	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case payload, ok := <-sink.ch:
			if !ok {
				return
			}
			data, err := json.Marshal(payload)
			if err != nil {
				log.Printf("linphone: SSE marshal error: %v", err)
				continue
			}
			fmt.Fprintf(w, "data: %s\n\n", data)
			flusher.Flush()
		case <-keepalive.C:
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		case <-r.Context().Done():
			log.Printf("linphone: SSE stream closed for session %s", sessionID)
			return
		}
	}
}

// sseEventSink implements EventSink by buffering payloads on a channel for the SSE handler.
type sseEventSink struct {
	ch   chan any
	done chan struct{}
}

func newSSEEventSink() *sseEventSink {
	return &sseEventSink{
		ch:   make(chan any, 16),
		done: make(chan struct{}),
	}
}

func (s *sseEventSink) SendJSON(payload any) error {
	select {
	case s.ch <- payload:
		return nil
	case <-s.done:
		return fmt.Errorf("event sink closed")
	default:
		return fmt.Errorf("event sink full, dropping event")
	}
}

func (s *sseEventSink) Ready() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *sseEventSink) close() {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
}

func writeLinphoneJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
