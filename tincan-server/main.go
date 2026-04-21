package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"tincan-server/agent_adapters"
	tincanapi "tincan-server/api"
	"tincan-server/calls"
	tincanconfig "tincan-server/config"
	"tincan-server/controllers"
	"tincan-server/conversations"
	"tincan-server/db"
	"tincan-server/output"
	tincanrouter "tincan-server/router"
)

type server struct {
	mu                  sync.Mutex
	callManager         *calls.Manager
	webrtcTransport     *webrtcTransport
	inference           *inferenceClient
	profiles            *tincanconfig.AgentProfileStore
	backends            *tincanconfig.AgentBackendStore
	conversations       *conversations.Store
	agentAdapters       map[string]agent_adapters.Adapter
	conversationService *ConversationService
	userInputController *controllers.UserInputController
	hookController      *controllers.HookController
	outputPublisher     *output.Publisher
	liveHub             *liveHub
}

type inferenceEnvelope struct {
	Kind        string `json:"kind"`
	RequestID   string `json:"request_id"`
	Action      string `json:"action"`
	Model       string `json:"model"`
	ContentType string `json:"content_type"`
	BodyLength  int    `json:"body_length"`
	SampleRate  int    `json:"sample_rate,omitempty"`
	Channels    int    `json:"channels,omitempty"`
	Voice       string `json:"voice,omitempty"`
	TextFormat  string `json:"text_format,omitempty"`
	Message     string `json:"message,omitempty"`
}

type inferenceMessage struct {
	Header inferenceEnvelope
	Body   []byte
}

type sttResult struct {
	Text string `json:"text"`
}

type inferenceClient struct {
	socketPath string
}

type inferenceSupervisor struct {
	socketPath string
	cmd        *exec.Cmd
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dataDirFlag := flag.String("data-dir", "", "directory for tincan-server runtime data")
	flag.Parse()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	dataDir, err := resolveDataDir(*dataDirFlag)
	if err != nil {
		log.Fatalf("failed to resolve data dir: %v", err)
	}

	inference := newInferenceSupervisor(inferenceSocketPath())
	if err := inference.EnsureRunning(ctx); err != nil {
		log.Fatalf("failed to start inference service: %v", err)
	}
	defer inference.Shutdown()

	srv, err := newServer(dataDir)
	if err != nil {
		log.Fatalf("failed to initialize server: %v", err)
	}
	defer func() {
		if err := srv.conversations.Close(); err != nil {
			log.Printf("failed to close conversation store: %v", err)
		}
	}()
	mux := http.NewServeMux()
	apiAdapters := make(map[string]tincanapi.ModelDiscoveringAdapter, len(srv.agentAdapters))
	for name, adapter := range srv.agentAdapters {
		apiAdapters[name] = adapter
	}
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/speak", srv.handleSpeakPage)
	mux.HandleFunc("/debug/audio/generated/", srv.handleGeneratedAudio)
	mux.HandleFunc("/hooks/opencode", srv.handleOpenCodeHook)
	tincanapi.Routes{
		Profiles:      srv.profiles,
		Backends:      srv.backends,
		Conversations: srv.conversations,
		Adapters:      apiAdapters,
	}.Register(mux)
	mux.Handle("/api/v1/live", srv.liveHub.handler())
	mux.HandleFunc("/session/", srv.handleSessionControl)
	srv.webrtcTransport.RegisterRoutes(mux)

	addr := "0.0.0.0:" + port
	log.Printf("tincan-server listening on %s", addr)
	httpServer := &http.Server{Addr: addr, Handler: mux}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server failed: %v", err)
	}
}

func newServer(dataDir string) (*server, error) {
	profiles, err := tincanconfig.NewAgentProfileStore(dataDir)
	if err != nil {
		return nil, fmt.Errorf("init agent profiles: %w", err)
	}

	backends, err := tincanconfig.NewAgentBackendStore(dataDir)
	if err != nil {
		return nil, fmt.Errorf("init agent backends: %w", err)
	}

	gormDB, err := db.OpenAndMigrate(dataDir)
	if err != nil {
		return nil, fmt.Errorf("init database: %w", err)
	}

	conversationStore := conversations.NewStore(gormDB)

	agentAdapters := agent_adapters.Default()
	for _, profile := range profiles.List() {
		backend, ok := backends.Get(profile.AgentBackend)
		if !ok {
			return nil, fmt.Errorf("unknown agent backend %q referenced by profile %q", profile.AgentBackend, profile.Name)
		}
		adapter, ok := agentAdapters[backend.Type]
		if !ok {
			return nil, fmt.Errorf("no agent adapter registered for backend type %q", backend.Type)
		}
		if err := adapter.ValidateBackend(profile.AgentBackend, backend); err != nil {
			return nil, err
		}
	}

	routerBackend, ok := backends.Get("__router__")
	var routerService controllers.Router
	var updateProcessor controllers.ConversationUpdateProcessor
	if !ok {
		log.Printf("router backend is not configured; voice command routing is unavailable until __router__ is added to config/agent_backends.json")
		routerService = unavailableRouter{reason: "router backend is not configured"}
	} else {
		routerAdapter, ok := agentAdapters[routerBackend.Type]
		if !ok {
			return nil, fmt.Errorf("no agent adapter registered for router backend type %q", routerBackend.Type)
		}
		if err := routerAdapter.ValidateBackend("__router__", routerBackend); err != nil {
			return nil, fmt.Errorf("validate router backend: %w", err)
		}

		builtRouter := NewRouter(routerBackend, routerAdapter, profiles)
		routerService = builtRouter
		updateProcessor = builtRouter
	}

	callManager := calls.NewManager()
	conversationService := NewConversationService(profiles, backends, conversationStore, agentAdapters)

	srv := &server{
		inference:           &inferenceClient{socketPath: inferenceSocketPath()},
		callManager:         callManager,
		profiles:            profiles,
		backends:            backends,
		conversations:       conversationStore,
		agentAdapters:       agentAdapters,
		conversationService: conversationService,
		userInputController: &controllers.UserInputController{
			Router:             routerService,
			Calls:              callManager,
			Conversations:      conversationStore,
			ConversationCreate: conversationCreator{service: conversationService},
			ConversationSend:   conversationMessenger{service: conversationService},
		},
		hookController: &controllers.HookController{
			Conversations:   conversationStore,
			Backends:        backends,
			Sessions:        callManager,
			UpdateProcessor: updateProcessor,
		},
	}
	srv.webrtcTransport = newWebRTCTransport(srv)
	srv.liveHub = newLiveHub(srv)
	srv.outputPublisher = output.NewPublisher(output.CallAudioListener{
		Renderer: callAudioRenderer{server: srv},
	}, srv.liveHub)
	return srv, nil
}

func resolveDataDir(flagValue string) (string, error) {
	if strings.TrimSpace(flagValue) != "" {
		return expandPath(flagValue)
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve user home dir: %w", err)
	}
	return filepath.Join(homeDir, ".tincan"), nil
}

func expandPath(path string) (string, error) {
	if path == "~" || strings.HasPrefix(path, "~/") {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve user home dir: %w", err)
		}
		if path == "~" {
			return homeDir, nil
		}
		return filepath.Join(homeDir, strings.TrimPrefix(path, "~/")), nil
	}
	return path, nil
}

type unavailableRouter struct {
	reason string
}

func (r unavailableRouter) RouteUserInput(_ tincanrouter.RouteUserInputRequest) (tincanrouter.RouteUserInputResult, error) {
	return tincanrouter.RouteUserInputResult{}, fmt.Errorf("%s", r.reason)
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":              "ok",
		"agent_profile_count": len(s.profiles.List()),
	})
}

func (s *server) handleSpeakPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(speakPageHTML))
}

func (s *server) handleGeneratedAudio(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	name := strings.TrimPrefix(r.URL.Path, "/debug/audio/generated/")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}

	generatedDir, err := serverAudioDir("generated-audio")
	if err != nil {
		http.Error(w, "audio storage unavailable", http.StatusInternalServerError)
		return
	}

	audioPath := filepath.Join(generatedDir, name)
	audioData, err := os.ReadFile(audioPath)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(audioData)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(audioData)
}

func (s *server) handleOpenCodeHook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	var event controllers.OpenCodeHookEvent
	if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if event.SessionID == "" {
		http.Error(w, "missing session id", http.StatusBadRequest)
		return
	}

	result, handled, err := s.hookController.HandleOpenCodeHook(event)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to handle hook: %v", err), http.StatusInternalServerError)
		return
	}
	if !handled {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if err := s.publishOutput(result.OutputEvents...); err != nil {
		http.Error(w, fmt.Sprintf("failed to publish hook output: %v", err), http.StatusInternalServerError)
		return
	}
	if result.ConversationID != "" {
		s.broadcastConversationMessageByID(result.ConversationID, result.MessageID)
		s.broadcastConversationSummaryByID(result.ConversationID)
	}

	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleSessionControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/session/")
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[1] == "utterance" {
		s.handleUtteranceUpload(w, r, parts[0])
		return
	}

	if len(parts) != 3 || parts[1] != "push-to-talk" {
		http.NotFound(w, r)
		return
	}

	sessionID := parts[0]
	action := parts[2]

	switch action {
	case "start", "stop":
	default:
		http.NotFound(w, r)
		return
	}

	if ok := s.callManager.SetPushToTalk(sessionID, action == "start"); !ok {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}

	log.Printf("peer %s push-to-talk %s", sessionID, action)
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleUtteranceUpload(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !s.callManager.HasSession(sessionID) {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}

	defer r.Body.Close()
	audioData, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read utterance body", http.StatusBadRequest)
		return
	}
	if len(audioData) == 0 {
		http.Error(w, "expected non-empty utterance audio", http.StatusBadRequest)
		return
	}

	contentType := r.Header.Get("Content-Type")
	responseBody, err := s.processUtterance(sessionID, audioData, contentType)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, responseBody)
}

func (s *server) processUtterance(sessionID string, audioData []byte, contentType string) (map[string]any, error) {
	if contentType == "" {
		contentType = "audio/wav"
	}

	if debugPath, err := saveUtteranceForDebug(sessionID, audioData); err == nil {
		log.Printf("peer %s saved utterance debug file: %s", sessionID, debugPath)
	} else {
		log.Printf("peer %s failed to save utterance debug file: %v", sessionID, err)
	}

	log.Printf("peer %s utterance upload: bytes=%d content_type=%s", sessionID, len(audioData), contentType)

	transcript, err := s.inference.transcribe(audioData, contentType)
	if err != nil {
		log.Printf("peer %s transcription failed: %v", sessionID, err)
		return nil, fmt.Errorf("transcription failed: %w", err)
	}

	log.Printf("peer %s transcript: %s", sessionID, transcript)

	handleResult, err := s.userInputController.HandleTranscript(sessionID, transcript)
	if err != nil {
		log.Printf("peer %s handle transcript failed: %v", sessionID, err)
		return nil, fmt.Errorf("handle transcript failed: %w", err)
	}
	routerResult := handleResult.RouteResult
	log.Printf("peer %s router action: %s agent_profile=%q handle=%q feedback=%q", sessionID, routerResult.Action, routerResult.AgentProfile, routerResult.ConversationHandle, routerResult.ImmediateFeedback)

	if err := s.publishOutput(handleResult.OutputEvents...); err != nil {
		log.Printf("peer %s publish output failed: %v", sessionID, err)
		return nil, fmt.Errorf("publish output failed: %w", err)
	}
	s.broadcastLiveUpdatesForHandleResult(handleResult.RouteResult, handleResult.ResponseBody)

	return handleResult.ResponseBody, nil
}

func (s *server) generateFeedbackAudio(text string) (string, error) {
	audioData, err := s.inference.synthesize(text)
	if err != nil {
		return "", err
	}

	generatedDir, err := serverAudioDir("generated-audio")
	if err != nil {
		return "", err
	}

	fileName := uuid.NewString() + ".wav"
	filePath := filepath.Join(generatedDir, fileName)
	if err := os.WriteFile(filePath, audioData, 0o644); err != nil {
		return "", err
	}

	return "/debug/audio/generated/" + fileName, nil
}

func (s *server) sendSessionEvent(sessionID string, payload any) {
	if ok := s.callManager.SendEvent(sessionID, payload); !ok {
		log.Printf("peer %s failed to send session event", sessionID)
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write json failed: %v", err)
	}
}

func (c *inferenceClient) transcribe(audioData []byte, contentType string) (string, error) {
	var lastErr error
	for attempt := 1; attempt <= 2; attempt += 1 {
		transcript, err := c.transcribeOnce(audioData, contentType)
		if err == nil {
			return transcript, nil
		}
		lastErr = err
		if err == io.EOF {
			log.Printf("inference socket EOF on attempt %d; retrying once", attempt)
			continue
		}
		return "", err
	}
	return "", lastErr
}

func (c *inferenceClient) synthesize(text string) ([]byte, error) {
	conn, err := net.Dial("unix", c.socketPath)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	body := []byte(text)
	request := inferenceMessage{
		Header: inferenceEnvelope{
			Kind:        "request",
			RequestID:   uuid.NewString(),
			Action:      "tts",
			Model:       "pockettts",
			ContentType: "text/plain",
			BodyLength:  len(body),
			Voice:       "alba",
		},
		Body: body,
	}

	if err := writeInferenceMessage(conn, request); err != nil {
		return nil, err
	}

	response, err := readInferenceMessage(conn)
	if err != nil {
		return nil, err
	}

	if response.Header.Kind == "error" {
		return nil, errors.New(response.Header.Message)
	}
	if response.Header.Kind != "result" || response.Header.Action != "tts" {
		return nil, fmt.Errorf("unexpected tts response: %+v", response.Header)
	}
	return response.Body, nil
}

func (c *inferenceClient) transcribeOnce(audioData []byte, contentType string) (string, error) {
	conn, err := net.Dial("unix", c.socketPath)
	if err != nil {
		return "", err
	}
	defer conn.Close()

	requestID := uuid.NewString()
	request := inferenceMessage{
		Header: inferenceEnvelope{
			Kind:        "request",
			RequestID:   requestID,
			Action:      "stt",
			Model:       "nvidia-parakeet",
			ContentType: contentType,
			BodyLength:  len(audioData),
		},
		Body: audioData,
	}

	if err := writeInferenceMessage(conn, request); err != nil {
		return "", err
	}

	response, err := readInferenceMessage(conn)
	if err != nil {
		return "", err
	}
	log.Printf("inference response header: kind=%s action=%s model=%s content_type=%s body_length=%d message=%q", response.Header.Kind, response.Header.Action, response.Header.Model, response.Header.ContentType, response.Header.BodyLength, response.Header.Message)
	if response.Header.Action == "stt" && len(response.Body) > 0 {
		log.Printf("inference response body: %s", string(response.Body))
	}

	if response.Header.Kind == "error" {
		return "", errors.New(response.Header.Message)
	}

	if response.Header.Kind != "result" || response.Header.Action != "stt" {
		return "", fmt.Errorf("unexpected inference response: %+v", response.Header)
	}

	var result sttResult
	if err := json.Unmarshal(response.Body, &result); err != nil {
		return "", err
	}
	return result.Text, nil
}

func writeInferenceMessage(writer io.Writer, message inferenceMessage) error {
	headerBytes, err := json.Marshal(message.Header)
	if err != nil {
		return err
	}

	var headerLength [4]byte
	binary.BigEndian.PutUint32(headerLength[:], uint32(len(headerBytes)))
	if _, err := writer.Write(headerLength[:]); err != nil {
		return err
	}
	if _, err := writer.Write(headerBytes); err != nil {
		return err
	}
	if len(message.Body) > 0 {
		if _, err := writer.Write(message.Body); err != nil {
			return err
		}
	}
	return nil
}

func readInferenceMessage(reader io.Reader) (inferenceMessage, error) {
	var headerLengthBytes [4]byte
	if _, err := io.ReadFull(reader, headerLengthBytes[:]); err != nil {
		return inferenceMessage{}, err
	}

	headerLength := binary.BigEndian.Uint32(headerLengthBytes[:])
	headerBytes := make([]byte, int(headerLength))
	if _, err := io.ReadFull(reader, headerBytes); err != nil {
		return inferenceMessage{}, err
	}

	var header inferenceEnvelope
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return inferenceMessage{}, err
	}

	body := make([]byte, header.BodyLength)
	if header.BodyLength > 0 {
		if _, err := io.ReadFull(reader, body); err != nil {
			return inferenceMessage{}, err
		}
	}

	return inferenceMessage{Header: header, Body: body}, nil
}

func inferenceSocketPath() string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return homeDir + "/Library/Application Support/tincan/run/inference.sock"
}

func serverAudioDir(parts ...string) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	dirParts := append([]string{homeDir, "Library", "Application Support", "tincan", "server-audio"}, parts...)
	dirPath := filepath.Join(dirParts...)
	if err := os.MkdirAll(dirPath, 0o755); err != nil {
		return "", err
	}

	return dirPath, nil
}

func saveUtteranceForDebug(sessionID string, audioData []byte) (string, error) {
	debugDir, err := serverAudioDir("utterances")
	if err != nil {
		return "", err
	}

	filePath := filepath.Join(debugDir, fmt.Sprintf("%s-%s.wav", sessionID, time.Now().UTC().Format("20060102T150405.000000000")))
	if err := os.WriteFile(filePath, audioData, 0o644); err != nil {
		return "", err
	}
	return filePath, nil
}

func newInferenceSupervisor(socketPath string) *inferenceSupervisor {
	return &inferenceSupervisor{socketPath: socketPath}
}

func (s *inferenceSupervisor) EnsureRunning(ctx context.Context) error {
	if isSocketReady(s.socketPath) {
		log.Printf("using existing inference service at %s", s.socketPath)
		return nil
	}

	command := exec.CommandContext(ctx, "swift", "run")
	command.Dir = filepath.Join("..", "tincan-inference-macos")
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr

	if err := command.Start(); err != nil {
		return err
	}
	log.Printf("started tincan-inference-macos with pid %d", command.Process.Pid)
	s.cmd = command

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if isSocketReady(s.socketPath) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}

	return fmt.Errorf("inference socket did not become ready at %s", s.socketPath)
}

func (s *inferenceSupervisor) Shutdown() {
	if s.cmd == nil || s.cmd.Process == nil {
		return
	}

	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	_, _ = s.cmd.Process.Wait()
	s.cmd = nil
}

func isSocketReady(socketPath string) bool {
	if socketPath == "" {
		return false
	}
	conn, err := net.DialTimeout("unix", socketPath, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
