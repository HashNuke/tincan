package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"

	tincanconfig "tincan-server/config"
)

type ModelDiscoveringAdapter interface {
	SupportsModelDiscovery() bool
	ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error)
}

type Routes struct {
	Profiles *tincanconfig.AgentProfileStore
	Backends *tincanconfig.AgentBackendStore
	Adapters map[string]ModelDiscoveringAdapter
}

type backendResponse struct {
	Name    string                           `json:"name"`
	Type    string                           `json:"type"`
	Options tincanconfig.AgentBackendOptions `json:"options"`
}

type backendTypeResponse struct {
	Type                string `json:"type"`
	SupportsModelLookup bool   `json:"supports_model_lookup"`
}

func (r Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("/api/v1/agent-profiles", r.handleAgentProfiles)
	mux.HandleFunc("/api/v1/agent-backends", r.handleAgentBackends)
	mux.HandleFunc("/api/v1/backend-types", r.handleBackendTypes)
	mux.HandleFunc("/api/v1/backend-types/", r.handleBackendTypeSubpath)
}

func (r Routes) handleAgentProfiles(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	profiles := append([]tincanconfig.AgentProfile(nil), r.Profiles.List()...)
	sort.Slice(profiles, func(i int, j int) bool {
		return strings.ToLower(profiles[i].Name) < strings.ToLower(profiles[j].Name)
	})

	writeJSON(w, http.StatusOK, map[string]any{
		"profiles": profiles,
	})
}

func (r Routes) handleAgentBackends(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	names := make([]string, 0, len(r.Backends.List()))
	for name := range r.Backends.List() {
		names = append(names, name)
	}
	sort.Strings(names)

	backends := make([]backendResponse, 0, len(names))
	for _, name := range names {
		backend, _ := r.Backends.Get(name)
		backends = append(backends, backendResponse{
			Name:    name,
			Type:    backend.Type,
			Options: backend.Options,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"backends": backends,
	})
}

func (r Routes) handleBackendTypes(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if req.URL.Path != "/api/v1/backend-types" {
		http.NotFound(w, req)
		return
	}

	backendTypes := make([]backendTypeResponse, 0, len(r.Adapters))
	for backendType, adapter := range r.Adapters {
		backendTypes = append(backendTypes, backendTypeResponse{
			Type:                backendType,
			SupportsModelLookup: adapter.SupportsModelDiscovery(),
		})
	}
	sort.Slice(backendTypes, func(i int, j int) bool {
		return backendTypes[i].Type < backendTypes[j].Type
	})

	writeJSON(w, http.StatusOK, map[string]any{
		"backend_types": backendTypes,
	})
}

func (r Routes) handleBackendTypeSubpath(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	rest := strings.TrimPrefix(req.URL.Path, "/api/v1/backend-types/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] != "models" {
		http.NotFound(w, req)
		return
	}

	backendType := parts[0]
	adapter, ok := r.Adapters[backendType]
	if !ok {
		http.Error(w, "unknown backend type", http.StatusNotFound)
		return
	}
	if !adapter.SupportsModelDiscovery() {
		http.Error(w, "model discovery is not supported for this backend type", http.StatusNotImplemented)
		return
	}

	models, err := adapter.ListModels(tincanconfig.AgentBackendDefinition{
		Type: backendType,
		Options: tincanconfig.AgentBackendOptions{
			ConnectionType: "command",
		},
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("list models failed: %v", err), http.StatusBadGateway)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"backend_type": backendType,
		"models":       models,
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write api json failed: %v", err)
	}
}
