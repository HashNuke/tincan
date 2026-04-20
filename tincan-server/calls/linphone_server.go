package calls

import (
	"fmt"
	"net/http"
)

type LinphoneServer struct {
	manager     *Manager
	debugWebRTC *WebRTCDebugServer
}

func NewLinphoneServer(manager *Manager) (*LinphoneServer, error) {
	debugWebRTC, err := NewWebRTCDebugServer(manager)
	if err != nil {
		return nil, fmt.Errorf("init debug webrtc transport: %w", err)
	}
	return &LinphoneServer{
		manager:     manager,
		debugWebRTC: debugWebRTC,
	}, nil
}

func (s *LinphoneServer) RegisterRoutes(mux *http.ServeMux) {
	// Temporary debug route while the real Liblinphone-facing call setup is implemented.
	mux.HandleFunc("/webrtc/offer", s.debugWebRTC.HandleOffer)
}
