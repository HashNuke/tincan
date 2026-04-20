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
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
)

type server struct {
	mu        sync.Mutex
	sessions  map[string]*sessionState
	api       *webrtc.API
	config    webrtc.Configuration
	inference *inferenceClient
}

type sessionState struct {
	peerConnection *webrtc.PeerConnection
	pushToTalk     bool
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

	srv := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/speak", srv.handleSpeakPage)
	mux.HandleFunc("/session/", srv.handleSessionControl)
	mux.HandleFunc("/webrtc/offer", srv.handleOffer)

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

func newServer() *server {
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		log.Fatalf("register codecs: %v", err)
	}

	interceptorRegistry := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(mediaEngine, interceptorRegistry); err != nil {
		log.Fatalf("register interceptors: %v", err)
	}

	api := webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithInterceptorRegistry(interceptorRegistry),
	)

	return &server{
		sessions:  make(map[string]*sessionState),
		api:       api,
		inference: &inferenceClient{socketPath: inferenceSocketPath()},
		config: webrtc.Configuration{
			ICEServers: []webrtc.ICEServer{
				{URLs: []string{"stun:stun.l.google.com:19302"}},
			},
		},
	}
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
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

	s.mu.Lock()
	session, ok := s.sessions[sessionID]
	if ok {
		switch action {
		case "start":
			session.pushToTalk = true
		case "stop":
			session.pushToTalk = false
		default:
			s.mu.Unlock()
			http.NotFound(w, r)
			return
		}
	}
	s.mu.Unlock()

	if !ok {
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

	s.mu.Lock()
	_, ok := s.sessions[sessionID]
	s.mu.Unlock()
	if !ok {
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
	writeJSON(w, http.StatusOK, map[string]any{"text": transcript})
}

func (s *server) handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()

	var offer webRTCOfferRequest
	if err := json.NewDecoder(r.Body).Decode(&offer); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}

	if offer.Type != "offer" || offer.SDP == "" {
		http.Error(w, "expected offer with non-empty sdp", http.StatusBadRequest)
		return
	}

	peerConnection, err := s.api.NewPeerConnection(s.config)
	if err != nil {
		log.Printf("new peer connection failed: %v", err)
		http.Error(w, "failed to create peer connection", http.StatusInternalServerError)
		return
	}

	sessionID := newSessionID()
	s.storePeer(sessionID, peerConnection)
	s.attachPeerLogging(sessionID, peerConnection)

	if _, err = peerConnection.AddTransceiverFromKind(
		webrtc.RTPCodecTypeAudio,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("add audio transceiver failed: %v", err)
		http.Error(w, "failed to add audio transceiver", http.StatusInternalServerError)
		return
	}

	remoteDescription := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offer.SDP,
	}
	if err = peerConnection.SetRemoteDescription(remoteDescription); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("set remote description failed: %v", err)
		http.Error(w, "failed to set remote description", http.StatusBadRequest)
		return
	}

	answer, err := peerConnection.CreateAnswer(nil)
	if err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("create answer failed: %v", err)
		http.Error(w, "failed to create answer", http.StatusInternalServerError)
		return
	}

	gatherComplete := webrtc.GatheringCompletePromise(peerConnection)
	if err = peerConnection.SetLocalDescription(answer); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("set local description failed: %v", err)
		http.Error(w, "failed to set local description", http.StatusInternalServerError)
		return
	}

	<-gatherComplete

	localDescription := peerConnection.LocalDescription()
	if localDescription == nil {
		s.closeAndDeletePeer(sessionID)
		http.Error(w, "missing local description", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, webRTCAnswerResponse{
		SessionID: sessionID,
		SDP:       localDescription.SDP,
		Type:      localDescription.Type.String(),
	})
}

func (s *server) attachPeerLogging(sessionID string, peerConnection *webrtc.PeerConnection) {
	peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("peer %s connection state: %s", sessionID, state.String())
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			s.closeAndDeletePeer(sessionID)
		}
	})

	peerConnection.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Printf("peer %s received %s track with codec %s; ignoring media for now", sessionID, track.Kind().String(), track.Codec().MimeType)
		go func() {
			for {
				packet, _, err := track.ReadRTP()
				if err != nil {
					log.Printf("peer %s track reader stopped: %v", sessionID, err)
					return
				}
				log.Printf(
					"peer %s audio packet: ssrc=%d payload_type=%d sequence=%d timestamp=%d marker=%t payload_bytes=%d",
					sessionID,
					packet.SSRC,
					packet.PayloadType,
					packet.SequenceNumber,
					packet.Timestamp,
					packet.Marker,
					len(packet.Payload),
				)
			}
		}()
	})
	peerConnection.OnDataChannel(func(dataChannel *webrtc.DataChannel) {
		log.Printf("peer %s opened data channel %q; ignoring messages for now", sessionID, dataChannel.Label())
	})
}

func (s *server) storePeer(sessionID string, peerConnection *webrtc.PeerConnection) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[sessionID] = &sessionState{peerConnection: peerConnection}
}

func (s *server) closeAndDeletePeer(sessionID string) {
	s.mu.Lock()
	session, ok := s.sessions[sessionID]
	if ok {
		delete(s.sessions, sessionID)
	}
	s.mu.Unlock()

	if ok {
		_ = session.peerConnection.Close()
	}
}

func newSessionID() string {
	return time.Now().UTC().Format("20060102T150405.000000000")
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

func saveUtteranceForDebug(sessionID string, audioData []byte) (string, error) {
	debugDir := filepath.Join("tmp", "utterances")
	if err := os.MkdirAll(debugDir, 0o755); err != nil {
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
