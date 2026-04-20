package calls

import "net/http"

type LinphoneServer struct {
	manager *Manager
}

func NewLinphoneServer(manager *Manager) (*LinphoneServer, error) {
	return &LinphoneServer{
		manager: manager,
	}, nil
}

func (s *LinphoneServer) RegisterRoutes(mux *http.ServeMux) {
	// Intentionally empty for now. Real Liblinphone-compatible transport routes will be added here.
}
