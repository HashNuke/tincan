package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
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
	"tincan-server/calls"
	"tincan-server/conversations"
	"tincan-server/db"
	tincanrouter "tincan-server/router"
)

type server struct {
	mu                  sync.Mutex
	callManager         *calls.Manager
	linphoneServer      *calls.LinphoneServer
	inference           *inferenceClient
	profiles            *AgentProfileStore
	backends            *AgentBackendStore
	conversations       *conversations.Store
	agentAdapters       map[string]agent_adapters.Adapter
	conversationService *ConversationService
	router              *Router
}

type webRTCOfferRequest struct {
	SDP  string `json:"sdp"`
	Type string `json:"type"`
}

type webRTCAnswerResponse struct {
	SessionID string `json:"session_id"`
	SDP       string `json:"sdp"`
	Type      string `json:"type"`
}

type openCodeHookEvent struct {
	EventType    string `json:"event_type"`
	SessionID    string `json:"session_id"`
	StatusType   string `json:"status_type,omitempty"`
	ErrorName    string `json:"error_name,omitempty"`
	ErrorMessage string `json:"error_message,omitempty"`
}

type pendingUpdateResponse struct {
	Updates []conversations.ConversationUpdate `json:"updates"`
}

type openCodeMessageWithParts struct {
	Info struct {
		Role string `json:"role"`
	} `json:"info"`
	Parts []struct {
		Type string `json:"type"`
		Text string `json:"text,omitempty"`
	} `json:"parts"`
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

	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	inference := newInferenceSupervisor(inferenceSocketPath())
	if err := inference.EnsureRunning(ctx); err != nil {
		log.Fatalf("failed to start inference service: %v", err)
	}
	defer inference.Shutdown()

	srv, err := newServer()
	if err != nil {
		log.Fatalf("failed to initialize server: %v", err)
	}
	defer func() {
		if err := srv.conversations.Close(); err != nil {
			log.Printf("failed to close conversation store: %v", err)
		}
	}()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", srv.handleHealth)
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/speak", srv.handleSpeakPage)
	mux.HandleFunc("/debug/audio/processing", srv.handleProcessingAudio)
	mux.HandleFunc("/debug/audio/generated/", srv.handleGeneratedAudio)
	mux.HandleFunc("/updates/pending", srv.handlePendingUpdates)
	mux.HandleFunc("/updates/", srv.handleUpdateActions)
	mux.HandleFunc("/hooks/opencode", srv.handleOpenCodeHook)
	mux.HandleFunc("/session/", srv.handleSessionControl)
	srv.linphoneServer.RegisterRoutes(mux)

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

func newServer() (*server, error) {
	profiles, err := NewAgentProfileStore()
	if err != nil {
		return nil, fmt.Errorf("init agent profiles: %w", err)
	}

	backends, err := NewAgentBackendStore()
	if err != nil {
		return nil, fmt.Errorf("init agent backends: %w", err)
	}

	gormDB, err := db.OpenAndMigrate()
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
	if !ok {
		return nil, fmt.Errorf("missing __router__ backend definition")
	}
	routerAdapter, ok := agentAdapters[routerBackend.Type]
	if !ok {
		return nil, fmt.Errorf("no agent adapter registered for router backend type %q", routerBackend.Type)
	}
	if err := routerAdapter.ValidateBackend("__router__", routerBackend); err != nil {
		return nil, fmt.Errorf("validate router backend: %w", err)
	}

	callManager := calls.NewManager()
	linphoneServer, err := calls.NewLinphoneServer(callManager)
	if err != nil {
		return nil, fmt.Errorf("init linphone server: %w", err)
	}

	return &server{
		inference:           &inferenceClient{socketPath: inferenceSocketPath()},
		callManager:         callManager,
		linphoneServer:      linphoneServer,
		profiles:            profiles,
		backends:            backends,
		conversations:       conversationStore,
		agentAdapters:       agentAdapters,
		conversationService: NewConversationService(profiles, backends, conversationStore, agentAdapters),
		router:              NewRouter(routerBackend, routerAdapter, profiles),
	}, nil
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

func (s *server) handleProcessingAudio(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	audioPath := filepath.Join("assets", "audio", "hold_on_processing_1.wav")
	audioData, err := os.ReadFile(audioPath)
	if err != nil {
		http.Error(w, "audio asset not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(audioData)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(audioData)
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

func (s *server) handlePendingUpdates(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	updates, err := s.conversations.ListPendingUpdates(20)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to list pending updates: %v", err), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, pendingUpdateResponse{Updates: updates})
}

func (s *server) handleUpdateActions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/updates/")
	parts := strings.Split(path, "/")
	if len(parts) != 2 || parts[1] != "consume" {
		http.NotFound(w, r)
		return
	}

	if err := s.conversations.ConsumeUpdate(parts[0]); err != nil {
		http.Error(w, fmt.Sprintf("failed to consume update: %v", err), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleOpenCodeHook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	var event openCodeHookEvent
	if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if event.SessionID == "" {
		http.Error(w, "missing session id", http.StatusBadRequest)
		return
	}

	conversation, ok, err := s.conversations.GetConversationByBackendConversationID(event.SessionID)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to find conversation: %v", err), http.StatusInternalServerError)
		return
	}
	if !ok {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch event.EventType {
	case "session.idle":
		if err := s.createConversationUpdateFromLatestAssistant(conversation); err != nil {
			log.Printf("failed to create conversation update for %s: %v", conversation.DisplayHandle, err)
		}
	case "session.error":
		_, err := s.conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
			ConversationID:     conversation.ID,
			ConversationHandle: conversation.DisplayHandle,
			SummaryText:        event.ErrorMessage,
			NotificationText:   conversation.DisplayHandle + " has an update.",
			RawUpdateJSON:      mustMarshalJSON(event),
			Status:             "pending",
		})
		if err != nil {
			log.Printf("failed to store error update for %s: %v", conversation.DisplayHandle, err)
		}
	}

	sessionID, hasSession := s.callManager.SessionIDForConversation(conversation.BackendConversationID)
	if hasSession {
		s.sendSessionEvent(sessionID, calls.NewNotifyEvent(conversation.DisplayHandle+" has an update.", "/debug/audio/processing"))
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
		http.Error(w, fmt.Sprintf("transcription failed: %v", err), http.StatusBadGateway)
		return
	}

	log.Printf("peer %s transcript: %s", sessionID, transcript)

	routerResult, err := s.router.RouteUserTranscript(tincanrouter.UserRouterInput{Transcript: transcript})
	if err != nil {
		log.Printf("peer %s router failed: %v", sessionID, err)
		http.Error(w, fmt.Sprintf("router failed: %v", err), http.StatusBadGateway)
		return
	}
	log.Printf("peer %s router action: %s agent_profile=%q handle=%q feedback=%q", sessionID, routerResult.Action, routerResult.AgentProfile, routerResult.ConversationHandle, routerResult.ImmediateFeedback)

	responsePayload := map[string]any{
		"text":   transcript,
		"router": routerResult,
	}
	if routerResult.ImmediateFeedback != "" {
		feedbackAudioURL, err := s.generateFeedbackAudio(routerResult.ImmediateFeedback)
		if err != nil {
			log.Printf("peer %s immediate feedback tts failed: %v", sessionID, err)
		} else {
			responsePayload["feedback_audio_url"] = feedbackAudioURL
			s.sendSessionEvent(sessionID, calls.NewPlayAudioEvent(routerResult.ImmediateFeedback, feedbackAudioURL))
		}
	}

	if routerResult.Action == "new_conversation" {
		conversation, err := s.conversationService.CreateConversation(ConversationCreateInput{
			ProfileName:       routerResult.AgentProfile,
			ConversationTitle: routerResult.ConversationTitle,
			Message:           routerResult.Message,
		})
		if err != nil {
			log.Printf("peer %s conversation creation failed: %v", sessionID, err)
			http.Error(w, fmt.Sprintf("conversation creation failed: %v", err), http.StatusBadGateway)
			return
		}
		log.Printf("peer %s created conversation: handle=%s backend_id=%s status=%s", sessionID, conversation.DisplayHandle, conversation.BackendConversationID, conversation.Status)
		if strings.TrimSpace(routerResult.UpdatedConversationNotes) != "" {
			if _, err := s.conversations.UpsertConversationNotes(conversation.ID, routerResult.UpdatedConversationNotes); err != nil {
				log.Printf("peer %s failed to persist conversation notes for %s: %v", sessionID, conversation.DisplayHandle, err)
			}
		}
		s.callManager.LinkConversation(sessionID, conversation.BackendConversationID)
		responsePayload["conversation"] = conversation
	}

	writeJSON(w, http.StatusOK, responsePayload)
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

func (s *server) createConversationUpdateFromLatestAssistant(conversation conversations.Conversation) error {
	backend, ok := s.backends.Get(conversation.AgentBackend)
	if !ok {
		return fmt.Errorf("unknown backend %q for conversation", conversation.AgentBackend)
	}
	if backend.Type != "opencode" || backend.Options.BaseURL == "" {
		return fmt.Errorf("conversation backend does not support OpenCode message fetch")
	}

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return err
	}
	messageURL := baseURL.ResolveReference(&url.URL{Path: strings.TrimRight(baseURL.Path, "/") + "/session/" + conversation.BackendConversationID + "/message"})
	query := messageURL.Query()
	query.Set("directory", conversation.WorkingDirectory)
	messageURL.RawQuery = query.Encode()

	resp, err := http.Get(messageURL.String())
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch session messages failed with status %d", resp.StatusCode)
	}

	var messages []openCodeMessageWithParts
	if err := json.NewDecoder(resp.Body).Decode(&messages); err != nil {
		return err
	}

	latestText := ""
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Info.Role != "assistant" {
			continue
		}
		for _, part := range messages[i].Parts {
			if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
				latestText = strings.TrimSpace(part.Text)
				break
			}
		}
		if latestText != "" {
			break
		}
	}
	if latestText == "" {
		latestText = "The agent has an update."
	}

	_, err = s.conversations.UpsertPendingUpdate(conversations.ConversationUpdate{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        latestText,
		NotificationText:   conversation.DisplayHandle + " has an update.",
		RawUpdateJSON:      mustMarshalJSON(messages),
		Status:             "pending",
	})
	return err
}

func mustMarshalJSON(v any) string {
	data, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(data)
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
		return nil, fmt.Errorf(response.Header.Message)
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
		return "", fmt.Errorf(response.Header.Message)
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
