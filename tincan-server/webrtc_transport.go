package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/pion/webrtc/v4"
)

type webrtcTransport struct {
	server *server

	mu       sync.Mutex
	sessions map[string]*webrtcSession
}

type webrtcSession struct {
	id             string
	peerConnection *webrtc.PeerConnection
	dataChannel    *webrtc.DataChannel
	eventSink      *webrtcDataChannelSink
}

type webrtcOfferRequest struct {
	OfferSDP string `json:"offer_sdp"`
}

type webrtcAnswerResponse struct {
	SessionID string `json:"session_id"`
	AnswerSDP string `json:"answer_sdp"`
}

type webrtcClientMessage struct {
	Type        string `json:"type"`
	RequestID   string `json:"request_id,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	AudioBase64 string `json:"audio_base64,omitempty"`
}

type webrtcUtteranceResult struct {
	Type             string `json:"type"`
	RequestID        string `json:"request_id,omitempty"`
	Text             string `json:"text"`
	FeedbackAudioURL string `json:"feedback_audio_url,omitempty"`
	Error            string `json:"error,omitempty"`
}

type webrtcDataChannelSink struct {
	channel *webrtc.DataChannel
	mu      sync.Mutex
	open    bool
}

func newWebRTCTransport(server *server) *webrtcTransport {
	return &webrtcTransport{
		server:   server,
		sessions: make(map[string]*webrtcSession),
	}
}

func (t *webrtcTransport) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/webrtc/session", t.handleRegisterSession)
	mux.HandleFunc("/webrtc/session/", t.handleSessionSubpath)
}

func (t *webrtcTransport) handleRegisterSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()
	var request webrtcOfferRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(request.OfferSDP) == "" {
		http.Error(w, "offer_sdp is required", http.StatusBadRequest)
		return
	}

	sessionID := uuid.NewString()
	log.Printf("webrtc: registering session %s", sessionID)
	peerConnection, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		log.Printf("webrtc: create peer connection failed for session %s: %v", sessionID, err)
		http.Error(w, fmt.Sprintf("create peer connection: %v", err), http.StatusInternalServerError)
		return
	}

	t.server.callManager.RegisterSession(sessionID)
	session := &webrtcSession{id: sessionID, peerConnection: peerConnection}
	t.storeSession(session)

	peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("webrtc: session %s state=%s", sessionID, state.String())
		switch state {
		case webrtc.PeerConnectionStateClosed, webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateDisconnected:
			t.closeSession(sessionID)
		}
	})

	peerConnection.OnDataChannel(func(dataChannel *webrtc.DataChannel) {
		if dataChannel.Label() != "tincan" {
			return
		}
		sink := &webrtcDataChannelSink{channel: dataChannel}
		t.attachDataChannel(sessionID, dataChannel, sink)
		dataChannel.OnOpen(func() {
			sink.setOpen(true)
			t.server.callManager.SetEventSink(sessionID, sink)
			log.Printf("webrtc: data channel open for session %s", sessionID)
		})
		dataChannel.OnClose(func() {
			sink.setOpen(false)
			t.server.callManager.SetEventSink(sessionID, nil)
			log.Printf("webrtc: data channel closed for session %s", sessionID)
		})
		dataChannel.OnError(func(err error) {
			log.Printf("webrtc: data channel error for session %s: %v", sessionID, err)
		})
		dataChannel.OnMessage(func(message webrtc.DataChannelMessage) {
			go t.handleClientMessage(sessionID, sink, message.Data)
		})
	})

	offer := webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: request.OfferSDP}
	if err := peerConnection.SetRemoteDescription(offer); err != nil {
		log.Printf("webrtc: rejected remote description for session %s: %v", sessionID, err)
		t.closeSession(sessionID)
		http.Error(w, fmt.Sprintf("set remote description: %v", err), http.StatusBadRequest)
		return
	}

	gatherComplete := webrtc.GatheringCompletePromise(peerConnection)
	answer, err := peerConnection.CreateAnswer(nil)
	if err != nil {
		log.Printf("webrtc: create answer failed for session %s: %v", sessionID, err)
		t.closeSession(sessionID)
		http.Error(w, fmt.Sprintf("create answer: %v", err), http.StatusInternalServerError)
		return
	}
	if err := peerConnection.SetLocalDescription(answer); err != nil {
		log.Printf("webrtc: set local description failed for session %s: %v", sessionID, err)
		t.closeSession(sessionID)
		http.Error(w, fmt.Sprintf("set local description: %v", err), http.StatusInternalServerError)
		return
	}
	<-gatherComplete

	localDescription := peerConnection.LocalDescription()
	if localDescription == nil {
		log.Printf("webrtc: missing local description for session %s", sessionID)
		t.closeSession(sessionID)
		http.Error(w, "missing local description", http.StatusInternalServerError)
		return
	}

	log.Printf("webrtc: session %s registered", sessionID)

	writeJSON(w, http.StatusOK, webrtcAnswerResponse{
		SessionID: sessionID,
		AnswerSDP: localDescription.SDP,
	})
}

func (t *webrtcTransport) handleSessionSubpath(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sessionID := strings.TrimPrefix(r.URL.Path, "/webrtc/session/")
	if strings.TrimSpace(sessionID) == "" {
		http.NotFound(w, r)
		return
	}

	t.closeSession(sessionID)
	w.WriteHeader(http.StatusNoContent)
}

func (t *webrtcTransport) handleClientMessage(sessionID string, sink *webrtcDataChannelSink, payload []byte) {
	var message webrtcClientMessage
	if err := json.Unmarshal(payload, &message); err != nil {
		log.Printf("webrtc: invalid client message for session %s: %v", sessionID, err)
		return
	}

	switch message.Type {
	case "utterance":
		audioData, err := base64.StdEncoding.DecodeString(message.AudioBase64)
		if err != nil {
			t.sendUtteranceResult(sink, webrtcUtteranceResult{
				Type:      "utterance_result",
				RequestID: message.RequestID,
				Error:     "invalid audio payload",
			})
			return
		}
		responseBody, err := t.server.processUtterance(sessionID, audioData, message.ContentType)
		if err != nil {
			t.sendUtteranceResult(sink, webrtcUtteranceResult{
				Type:      "utterance_result",
				RequestID: message.RequestID,
				Error:     err.Error(),
			})
			return
		}
		result := webrtcUtteranceResult{
			Type:      "utterance_result",
			RequestID: message.RequestID,
		}
		if text, ok := responseBody["text"].(string); ok {
			result.Text = text
		}
		if feedbackAudioURL, ok := responseBody["feedback_audio_url"].(string); ok {
			result.FeedbackAudioURL = feedbackAudioURL
		}
		t.sendUtteranceResult(sink, result)
	default:
		log.Printf("webrtc: unsupported client message type for session %s: %s", sessionID, message.Type)
	}
}

func (t *webrtcTransport) sendUtteranceResult(sink *webrtcDataChannelSink, result webrtcUtteranceResult) {
	if err := sink.SendJSON(result); err != nil {
		log.Printf("webrtc: failed to send utterance result: %v", err)
	}
}

func (t *webrtcTransport) storeSession(session *webrtcSession) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sessions[session.id] = session
}

func (t *webrtcTransport) attachDataChannel(sessionID string, dataChannel *webrtc.DataChannel, sink *webrtcDataChannelSink) {
	t.mu.Lock()
	defer t.mu.Unlock()
	session, ok := t.sessions[sessionID]
	if !ok {
		return
	}
	session.dataChannel = dataChannel
	session.eventSink = sink
}

func (t *webrtcTransport) closeSession(sessionID string) {
	t.mu.Lock()
	session, ok := t.sessions[sessionID]
	if ok {
		delete(t.sessions, sessionID)
	}
	t.mu.Unlock()
	if !ok {
		return
	}

	t.server.callManager.SetEventSink(sessionID, nil)
	t.server.callManager.RemoveSession(sessionID)
	if session.dataChannel != nil {
		_ = session.dataChannel.Close()
	}
	if session.peerConnection != nil {
		_ = session.peerConnection.Close()
	}
	log.Printf("webrtc: closed session %s", sessionID)
}

func (s *webrtcDataChannelSink) SendJSON(payload any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.open {
		return errors.New("data channel not open")
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return s.channel.SendText(string(data))
}

func (s *webrtcDataChannelSink) Ready() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.open
}

func (s *webrtcDataChannelSink) setOpen(open bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.open = open
}
