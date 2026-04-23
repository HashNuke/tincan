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
)

const (
	serverControlSocketFileName = "tincan-server.sock"
	inferenceSocketFileName     = "tincan-inference-macos.sock"
)

var buildVersion = "dev"

type server struct {
	mu                  sync.Mutex
	callManager         *calls.Manager
	webrtcTransport     *webrtcTransport
	speechRuntime       speechRuntime
	stt                 speechToTextService
	tts                 textToSpeechService
	credentialStore     *serviceCredentialStore
	appConfig           *tincanconfig.AppConfigStore
	profiles            *tincanconfig.AgentProfileStore
	backends            *tincanconfig.AgentBackendStore
	conversations       *conversations.Store
	agentAdapters       map[string]agent_adapters.Adapter
	managedScheduler    *ManagedRunScheduler
	conversationService *ConversationService
	userInputController *controllers.UserInputController
	hookController      *controllers.HookController
	outputPublisher     *output.Publisher
	liveHub             *liveHub
	controlSocket       *serverControlSocket
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
	sttModel   string
	ttsModel   string
	ttsVoice   string
}

type inferenceSupervisor struct {
	socketPath string
	cmd        *exec.Cmd
	launch     inferenceLaunchConfiguration
	launchErr  error
	output     io.Writer
}

type inferenceLaunchConfiguration struct {
	command          string
	args             []string
	workingDirectory string
}

type bundledRuntimeLayout struct {
	rootDir             string
	modelsDir           string
	inferenceExecutable string
}

const (
	defaultBundledSTTModel = tincanconfig.DefaultSTTModel
	defaultBundledTTSModel = tincanconfig.DefaultTTSModel
	defaultServerPort      = 4490
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dataDirFlag := flag.String("data-dir", "", "directory for tincan-server runtime data")
	logFileFlag := flag.String("log-file", "", "file path for tincan-server logs")
	portFlag := flag.Int("port", defaultServerPort, "HTTP port for tincan-server")
	flag.Parse()

	logFile, resolvedLogFilePath, err := openLogFile(*logFileFlag)
	if err != nil {
		log.Fatalf("failed to open log file: %v", err)
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

	if *portFlag <= 0 || *portFlag > 65535 {
		log.Fatalf("invalid --port: %d", *portFlag)
	}

	dataDir, err := resolveDataDir(*dataDirFlag)
	if err != nil {
		log.Fatalf("failed to resolve data dir: %v", err)
	}

	srv, err := newServer(dataDir, *portFlag, runtimeOutput)
	if err != nil {
		log.Fatalf("failed to initialize server: %v", err)
	}
	defer func() {
		if err := srv.conversations.Close(); err != nil {
			log.Printf("failed to close conversation store: %v", err)
		}
	}()
	if err := srv.controlSocket.Start(ctx); err != nil {
		log.Fatalf("failed to start control socket: %v", err)
	}
	defer srv.controlSocket.Shutdown()

	if err := srv.speechRuntime.EnsureRunning(ctx); err != nil {
		log.Fatalf("failed to start speech services: %v", err)
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

	addr := fmt.Sprintf("0.0.0.0:%d", *portFlag)
	log.Printf("tincan-server %s listening on %s", buildVersion, addr)
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

func newServer(dataDir string, port int, runtimeOutput io.Writer) (*server, error) {
	appConfig, err := tincanconfig.NewAppConfigStore(dataDir)
	if err != nil {
		return nil, fmt.Errorf("init app config: %w", err)
	}

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
	credentials := newServiceCredentialReader()
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

	builtRouter := NewRouter(appConfig, profiles, backends, agentAdapters)
	if err := builtRouter.ValidateConfiguration(); err != nil {
		log.Printf("router is not configured; voice command routing is unavailable until config/config.json sets router_profile to a valid agent profile: %v", err)
	}
	var routerService controllers.Router = builtRouter

	callManager := calls.NewManager()
	tincanExecPath, err := resolveTincanExecPath()
	if err != nil {
		return nil, err
	}
	serverURL := fmt.Sprintf("http://127.0.0.1:%d", port)
	managedScheduler := NewManagedRunScheduler(serverURL, tincanExecPath, conversationStore, backends, agentAdapters)
	if runtimeOutput != nil {
		managedScheduler.stdout = runtimeOutput
		managedScheduler.stderr = runtimeOutput
	}
	conversationService := NewConversationService(profiles, backends, conversationStore, agentAdapters, managedScheduler)
	speechServices, err := newSpeechServiceSet(appConfig, runtimeOutput, credentials)
	if err != nil {
		return nil, fmt.Errorf("init speech services: %w", err)
	}

	srv := &server{
		speechRuntime:       speechServices.runtime,
		stt:                 speechServices.stt,
		tts:                 speechServices.tts,
		credentialStore:     credentials,
		callManager:         callManager,
		appConfig:           appConfig,
		profiles:            profiles,
		backends:            backends,
		conversations:       conversationStore,
		agentAdapters:       agentAdapters,
		managedScheduler:    managedScheduler,
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
			Sessions:        callManager,
			UpdateProcessor: builtRouter,
		},
		controlSocket: newServerControlSocket(serverControlSocketPath(), credentials),
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

func openLogFile(flagValue string) (*os.File, string, error) {
	if strings.TrimSpace(flagValue) == "" {
		return nil, "", nil
	}

	logFilePath, err := expandPath(flagValue)
	if err != nil {
		return nil, "", fmt.Errorf("expand log file path: %w", err)
	}

	logDirectory := filepath.Dir(logFilePath)
	if logDirectory != "." {
		if err := os.MkdirAll(logDirectory, 0o755); err != nil {
			return nil, "", fmt.Errorf("create log directory: %w", err)
		}
	}

	logFile, err := os.OpenFile(logFilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, "", fmt.Errorf("open log file: %w", err)
	}

	return logFile, logFilePath, nil
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":              "ok",
		"agent_profile_count": len(s.profiles.List()),
	})
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
	if strings.TrimSpace(event.ConversationID) == "" {
		http.Error(w, "missing conversation id", http.StatusBadRequest)
		return
	}
	log.Printf(
		"opencode hook received: conversation_id=%q event_type=%q session_id=%q message_id=%q part_id=%q status_type=%q error_name=%q error_message=%q",
		event.ConversationID,
		event.EventType,
		event.SessionID,
		event.MessageID,
		event.PartID,
		event.StatusType,
		event.ErrorName,
		event.ErrorMessage,
	)

	result, handled, err := s.hookController.HandleOpenCodeHook(event)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to handle hook: %v", err), http.StatusInternalServerError)
		return
	}
	if !handled {
		log.Printf("opencode hook ignored: conversation_id=%q session_id=%q", event.ConversationID, event.SessionID)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	switch event.EventType {
	case "session.idle":
		if s.managedScheduler != nil {
			if err := s.managedScheduler.HandleSessionIdle(event.ConversationID); err != nil {
				http.Error(w, fmt.Sprintf("failed to advance managed conversation on idle: %v", err), http.StatusInternalServerError)
				return
			}
		}
	case "session.error":
		if s.managedScheduler != nil {
			if err := s.managedScheduler.HandleSessionError(event.ConversationID, firstNonEmpty(event.ErrorMessage, event.ErrorName)); err != nil {
				http.Error(w, fmt.Sprintf("failed to mark managed conversation failed: %v", err), http.StatusInternalServerError)
				return
			}
		}
	}
	if err := s.publishOutput(result.OutputEvents...); err != nil {
		http.Error(w, fmt.Sprintf("failed to publish hook output: %v", err), http.StatusInternalServerError)
		return
	}
	if result.ConversationID != "" {
		s.broadcastConversationSummaryByID(result.ConversationID)
		s.broadcastConversationMessageByID(result.ConversationID, result.MessageID)
	}
	log.Printf(
		"opencode hook handled: conversation_id=%q session_id=%q message_id=%q output_events=%d",
		result.ConversationID,
		event.SessionID,
		result.MessageID,
		len(result.OutputEvents),
	)

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

	transcript, err := s.stt.transcribe(audioData, contentType)
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

func (s *server) sendSessionEvent(sessionID string, payload any) {
	if ok := s.callManager.SendEvent(sessionID, payload); !ok {
		log.Printf("peer %s failed to send session event", sessionID)
	}
}

func (s *server) queueSessionAudio(sessionID string, audioData []byte) error {
	if s == nil {
		return errors.New("server is not configured")
	}
	if s.webrtcTransport == nil {
		return errors.New("webrtc transport is not configured")
	}
	if len(audioData) == 0 {
		return errors.New("audio payload is empty")
	}
	return s.webrtcTransport.QueueSessionAudio(sessionID, audioData)
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
			Model:       c.ttsModel,
			ContentType: "text/plain",
			BodyLength:  len(body),
			Voice:       c.ttsVoice,
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
			Model:       c.sttModel,
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
	runDir := runtimeRunDirectory()
	if runDir == "" {
		return ""
	}
	return filepath.Join(runDir, inferenceSocketFileName)
}

func serverControlSocketPath() string {
	runDir := runtimeRunDirectory()
	if runDir == "" {
		return ""
	}
	return filepath.Join(runDir, serverControlSocketFileName)
}

func runtimeRunDirectory() string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(homeDir, "Library", "Application Support", "tincan", "run")
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

func newInferenceSupervisor(socketPath string, appConfig *tincanconfig.AppConfigStore, output io.Writer) *inferenceSupervisor {
	launch, err := resolveInferenceLaunchConfiguration(socketPath, appConfig)
	return &inferenceSupervisor{
		socketPath: socketPath,
		launch:     launch,
		launchErr:  err,
		output:     output,
	}
}

func (s *inferenceSupervisor) EnsureRunning(ctx context.Context) error {
	if s.launchErr != nil {
		return s.launchErr
	}

	if err := clearExistingInferenceProcesses(ctx, knownInferenceSocketPaths()); err != nil {
		return fmt.Errorf("clear existing inference service: %w", err)
	}

	command := exec.CommandContext(ctx, s.launch.command, s.launch.args...)
	if s.launch.workingDirectory != "" {
		command.Dir = s.launch.workingDirectory
	}
	if s.output == nil {
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
	} else {
		command.Stdout = s.output
		command.Stderr = s.output
	}

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

func resolveInferenceLaunchConfiguration(socketPath string, appConfig *tincanconfig.AppConfigStore) (inferenceLaunchConfiguration, error) {
	if launch, handled, err := resolveInferenceLaunchFromEnvironment(socketPath, appConfig); handled {
		return launch, err
	}

	if launch, ok := resolveBundledInferenceLaunch(socketPath, appConfig); ok {
		return launch, nil
	}

	if launch, handled, err := resolveSourceTreeInferenceLaunch(socketPath, appConfig); handled {
		return launch, err
	}

	return inferenceLaunchConfiguration{}, fmt.Errorf(
		"unable to locate tincan-inference-macos launcher; bundle BundledRuntime with tincan-server, tincan-inference-macos, and BundledRuntime/models or set TINCAN_INFERENCE_EXECUTABLE and TINCAN_MODELS_DIR",
	)
}

func resolveInferenceLaunchFromEnvironment(socketPath string, appConfig *tincanconfig.AppConfigStore) (inferenceLaunchConfiguration, bool, error) {
	executablePath := strings.TrimSpace(os.Getenv("TINCAN_INFERENCE_EXECUTABLE"))
	if executablePath == "" {
		return inferenceLaunchConfiguration{}, false, nil
	}

	modelsDir := firstNonEmpty(
		strings.TrimSpace(os.Getenv("TINCAN_MODELS_DIR")),
		strings.TrimSpace(os.Getenv("TINCAN_INFERENCE_MODELS_DIR")),
	)
	if modelsDir == "" {
		return inferenceLaunchConfiguration{}, true, fmt.Errorf(
			"TINCAN_INFERENCE_EXECUTABLE requires TINCAN_MODELS_DIR (or TINCAN_INFERENCE_MODELS_DIR)",
		)
	}

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	return compiledInferenceLaunch(
		executablePath,
		modelsDir,
		sttModel,
		ttsModel,
		socketPath,
	), true, nil
}

func resolveBundledInferenceLaunch(socketPath string, appConfig *tincanconfig.AppConfigStore) (inferenceLaunchConfiguration, bool) {
	layoutCandidates := []bundledRuntimeLayout{}

	if layout, ok := bundledRuntimeLayoutFromExecutable(); ok {
		layoutCandidates = append(layoutCandidates, layout)
	}

	if layout, ok := bundledRuntimeLayoutFromRoot(
		filepath.Clean(filepath.Join("..", "tincan-swift-app", "BundledRuntime")),
	); ok {
		layoutCandidates = append(layoutCandidates, layout)
	}

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	for _, layout := range layoutCandidates {
		return compiledInferenceLaunch(
			layout.inferenceExecutable,
			layout.modelsDir,
			sttModel,
			ttsModel,
			socketPath,
		), true
	}

	return inferenceLaunchConfiguration{}, false
}

func resolveSourceTreeInferenceLaunch(socketPath string, appConfig *tincanconfig.AppConfigStore) (inferenceLaunchConfiguration, bool, error) {
	modelsDir := firstNonEmpty(
		strings.TrimSpace(os.Getenv("TINCAN_MODELS_DIR")),
		strings.TrimSpace(os.Getenv("TINCAN_INFERENCE_MODELS_DIR")),
	)
	if modelsDir == "" {
		return inferenceLaunchConfiguration{}, false, nil
	}

	packageDir := filepath.Clean(filepath.Join("..", "tincan-inference-macos"))
	if !fileExists(filepath.Join(packageDir, "Package.swift")) {
		return inferenceLaunchConfiguration{}, false, nil
	}

	sttModel, ttsModel := configuredInferenceModels(appConfig)
	args := []string{
		"run",
		"--package-path", packageDir,
		"tincan-inference-macos",
		"--models-dir", modelsDir,
		"--stt-model", sttModel,
		"--tts-model", ttsModel,
		"--socket-path", socketPath,
	}

	return inferenceLaunchConfiguration{
		command: "swift",
		args:    args,
	}, true, nil
}

func configuredInferenceModels(appConfig *tincanconfig.AppConfigStore) (string, string) {
	return inferenceModelForSelection(configuredSTTSelection(appConfig), defaultBundledSTTModel),
		inferenceModelForSelection(configuredTTSSelection(appConfig), defaultBundledTTSModel)
}

func compiledInferenceLaunch(
	executablePath string,
	modelsDir string,
	sttModel string,
	ttsModel string,
	socketPath string,
) inferenceLaunchConfiguration {
	return inferenceLaunchConfiguration{
		command: executablePath,
		args: []string{
			"--models-dir", modelsDir,
			"--stt-model", sttModel,
			"--tts-model", ttsModel,
			"--socket-path", socketPath,
		},
	}
}

func bundledRuntimeLayoutFromExecutable() (bundledRuntimeLayout, bool) {
	executablePath, err := os.Executable()
	if err != nil {
		return bundledRuntimeLayout{}, false
	}

	rootDir := filepath.Dir(executablePath)
	return bundledRuntimeLayoutFromRoot(rootDir)
}

func bundledRuntimeLayoutFromRoot(rootDir string) (bundledRuntimeLayout, bool) {
	layout := bundledRuntimeLayout{
		rootDir:             rootDir,
		modelsDir:           filepath.Join(rootDir, "models"),
		inferenceExecutable: filepath.Join(rootDir, "tincan-inference-macos"),
	}

	if !fileExists(layout.inferenceExecutable) || !directoryExists(layout.modelsDir) {
		return bundledRuntimeLayout{}, false
	}

	return layout, true
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

func directoryExists(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.IsDir()
}
