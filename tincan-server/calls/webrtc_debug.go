package calls

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
)

type WebRTCOfferRequest struct {
	SDP  string `json:"sdp"`
	Type string `json:"type"`
}

type WebRTCAnswerResponse struct {
	SessionID string `json:"session_id"`
	SDP       string `json:"sdp"`
	Type      string `json:"type"`
}

type WebRTCDebugServer struct {
	api     *webrtc.API
	config  webrtc.Configuration
	manager *Manager
	peers   map[string]*webrtc.PeerConnection
}

func NewWebRTCDebugServer(manager *Manager) (*WebRTCDebugServer, error) {
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		return nil, fmt.Errorf("register codecs: %w", err)
	}
	interceptorRegistry := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(mediaEngine, interceptorRegistry); err != nil {
		return nil, fmt.Errorf("register interceptors: %w", err)
	}
	api := webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithInterceptorRegistry(interceptorRegistry),
	)
	return &WebRTCDebugServer{
		api:     api,
		manager: manager,
		peers:   make(map[string]*webrtc.PeerConnection),
		config:  webrtc.Configuration{ICEServers: []webrtc.ICEServer{{URLs: []string{"stun:stun.l.google.com:19302"}}}},
	}, nil
}

func (s *WebRTCDebugServer) HandleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()

	var offer WebRTCOfferRequest
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
	s.manager.RegisterSession(sessionID)
	s.peers[sessionID] = peerConnection
	s.attachPeerLogging(sessionID, peerConnection)

	if _, err = peerConnection.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		s.closeAndDeletePeer(sessionID)
		http.Error(w, "failed to add audio transceiver", http.StatusInternalServerError)
		return
	}

	if err = peerConnection.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer.SDP}); err != nil {
		s.closeAndDeletePeer(sessionID)
		http.Error(w, "failed to set remote description", http.StatusBadRequest)
		return
	}

	answer, err := peerConnection.CreateAnswer(nil)
	if err != nil {
		s.closeAndDeletePeer(sessionID)
		http.Error(w, "failed to create answer", http.StatusInternalServerError)
		return
	}

	gatherComplete := webrtc.GatheringCompletePromise(peerConnection)
	if err = peerConnection.SetLocalDescription(answer); err != nil {
		s.closeAndDeletePeer(sessionID)
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

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(WebRTCAnswerResponse{SessionID: sessionID, SDP: localDescription.SDP, Type: localDescription.Type.String()})
}

func (s *WebRTCDebugServer) attachPeerLogging(sessionID string, peerConnection *webrtc.PeerConnection) {
	peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("peer %s connection state: %s", sessionID, state.String())
		if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateDisconnected {
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
				log.Printf("peer %s audio packet: ssrc=%d payload_type=%d sequence=%d timestamp=%d marker=%t payload_bytes=%d", sessionID, packet.SSRC, packet.PayloadType, packet.SequenceNumber, packet.Timestamp, packet.Marker, len(packet.Payload))
			}
		}()
	})
	peerConnection.OnDataChannel(func(dataChannel *webrtc.DataChannel) {
		log.Printf("peer %s opened data channel %q", sessionID, dataChannel.Label())
		if dataChannel.Label() == "events" {
			s.manager.SetEventSink(sessionID, webrtcDataChannelSink{channel: dataChannel})
		}
	})
}

func (s *WebRTCDebugServer) closeAndDeletePeer(sessionID string) {
	s.manager.RemoveSession(sessionID)
	if pc, ok := s.peers[sessionID]; ok {
		_ = pc.Close()
		delete(s.peers, sessionID)
	}
}

type webrtcDataChannelSink struct {
	channel *webrtc.DataChannel
}

func (s webrtcDataChannelSink) SendJSON(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return s.channel.SendText(string(data))
}

func (s webrtcDataChannelSink) Ready() bool {
	return s.channel != nil && s.channel.ReadyState() == webrtc.DataChannelStateOpen
}

func newSessionID() string {
	return time.Now().UTC().Format("20060102T150405.000000000")
}
