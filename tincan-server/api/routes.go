package api

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
)

type ModelDiscoveringAdapter interface {
	ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error
	SupportsModelDiscovery() bool
	ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error)
}

type Routes struct {
	AppConfig     *tincanconfig.AppConfigStore
	Profiles      *tincanconfig.AgentProfileStore
	Backends      *tincanconfig.AgentBackendStore
	Conversations *conversations.Store
	Adapters      map[string]ModelDiscoveringAdapter
}

type backendResponse struct {
	Name    string                           `json:"name"`
	Type    string                           `json:"type"`
	Options tincanconfig.AgentBackendOptions `json:"options"`
}

type backendUpsertRequest struct {
	Name    string                           `json:"name"`
	Type    string                           `json:"type"`
	Options tincanconfig.AgentBackendOptions `json:"options"`
}

type backendTypeResponse struct {
	Type                string `json:"type"`
	SupportsModelLookup bool   `json:"supports_model_lookup"`
}

type conversationsResponse struct {
	NextCursor    string                              `json:"next_cursor,omitempty"`
	Conversations []conversations.ConversationSummary `json:"conversations"`
}

type conversationResponse struct {
	ID               string    `json:"id"`
	Handle           string    `json:"handle"`
	AgentProfileName string    `json:"agent_profile_name"`
	AgentBackend     string    `json:"agent_backend"`
	WorkingDirectory string    `json:"working_directory"`
	Status           string    `json:"status"`
	UpdatedAt        time.Time `json:"updated_at"`
	PreviewText      string    `json:"preview_text"`
	HasPendingUpdate bool      `json:"has_pending_update"`
}

type conversationMessagesResponse struct {
	Conversation conversationResponse           `json:"conversation"`
	NextCursor   string                         `json:"next_cursor,omitempty"`
	Messages     []conversations.MessageSummary `json:"messages"`
}

func (r Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("/api/v1/agent-profiles", r.handleAgentProfiles)
	mux.HandleFunc("/api/v1/agent-profiles/", r.handleAgentProfileSubpath)
	mux.HandleFunc("/api/v1/agent-backends", r.handleAgentBackends)
	mux.HandleFunc("/api/v1/agent-backends/", r.handleAgentBackendSubpath)
	mux.HandleFunc("/api/v1/backend-types", r.handleBackendTypes)
	mux.HandleFunc("/api/v1/backend-types/", r.handleBackendTypeSubpath)
	mux.HandleFunc("/api/v1/conversations", r.handleConversations)
	mux.HandleFunc("/api/v1/conversations/", r.handleConversationSubpath)
}

func (r Routes) handleAgentProfiles(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case http.MethodGet:
		r.listAgentProfiles(w, req)
	case http.MethodPost:
		r.createAgentProfile(w, req)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (r Routes) listAgentProfiles(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/api/v1/agent-profiles" {
		http.NotFound(w, req)
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
	switch req.Method {
	case http.MethodGet:
		r.listAgentBackends(w, req)
	case http.MethodPost:
		r.createAgentBackend(w, req)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (r Routes) listAgentBackends(w http.ResponseWriter, req *http.Request) {
	if req.URL.Path != "/api/v1/agent-backends" {
		http.NotFound(w, req)
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

func (r Routes) handleAgentProfileSubpath(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/api/v1/agent-profiles/")
	if strings.TrimSpace(name) == "" || strings.Contains(name, "/") {
		http.NotFound(w, req)
		return
	}

	switch req.Method {
	case http.MethodPatch:
		r.updateAgentProfile(w, req, name)
	case http.MethodDelete:
		r.deleteAgentProfile(w, req, name)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (r Routes) handleAgentBackendSubpath(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/api/v1/agent-backends/")
	if strings.TrimSpace(name) == "" || strings.Contains(name, "/") {
		http.NotFound(w, req)
		return
	}

	switch req.Method {
	case http.MethodPatch:
		r.updateAgentBackend(w, req, name)
	case http.MethodDelete:
		r.deleteAgentBackend(w, req, name)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
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

func (r Routes) handleConversations(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if req.URL.Path != "/api/v1/conversations" {
		http.NotFound(w, req)
		return
	}
	if r.Conversations == nil {
		http.Error(w, "conversations are unavailable", http.StatusServiceUnavailable)
		return
	}

	pageSize := 20
	if rawPageSize := strings.TrimSpace(req.URL.Query().Get("page_size")); rawPageSize != "" {
		parsedPageSize, err := strconv.Atoi(rawPageSize)
		if err != nil || parsedPageSize <= 0 {
			http.Error(w, "page_size must be a positive integer", http.StatusBadRequest)
			return
		}
		if parsedPageSize > 100 {
			parsedPageSize = 100
		}
		pageSize = parsedPageSize
	}

	cursor, err := decodeConversationSummaryCursor(strings.TrimSpace(req.URL.Query().Get("cursor")))
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid cursor: %v", err), http.StatusBadRequest)
		return
	}

	result, err := r.Conversations.ListConversationSummaries(conversations.ListConversationSummariesParams{
		Cursor:   cursor,
		PageSize: pageSize,
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("list conversations failed: %v", err), http.StatusInternalServerError)
		return
	}

	response := conversationsResponse{
		Conversations: result.Conversations,
	}
	if result.NextCursor != nil {
		encodedCursor, err := encodeConversationSummaryCursor(*result.NextCursor)
		if err != nil {
			http.Error(w, fmt.Sprintf("encode cursor failed: %v", err), http.StatusInternalServerError)
			return
		}
		response.NextCursor = encodedCursor
	}

	writeJSON(w, http.StatusOK, response)
}

func (r Routes) handleConversationSubpath(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.Conversations == nil {
		http.Error(w, "conversations are unavailable", http.StatusServiceUnavailable)
		return
	}

	rest := strings.TrimPrefix(req.URL.Path, "/api/v1/conversations/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || parts[1] != "messages" {
		http.NotFound(w, req)
		return
	}

	r.listConversationMessages(w, req, parts[0])
}

func (r Routes) listConversationMessages(w http.ResponseWriter, req *http.Request, conversationID string) {
	conversation, ok, err := r.Conversations.GetConversationByID(conversationID)
	if err != nil {
		http.Error(w, fmt.Sprintf("get conversation failed: %v", err), http.StatusInternalServerError)
		return
	}
	if !ok {
		http.Error(w, "conversation not found", http.StatusNotFound)
		return
	}

	pageSize := 50
	if rawPageSize := strings.TrimSpace(req.URL.Query().Get("page_size")); rawPageSize != "" {
		parsedPageSize, err := strconv.Atoi(rawPageSize)
		if err != nil || parsedPageSize <= 0 {
			http.Error(w, "page_size must be a positive integer", http.StatusBadRequest)
			return
		}
		if parsedPageSize > 100 {
			parsedPageSize = 100
		}
		pageSize = parsedPageSize
	}

	cursor, err := decodeMessageHistoryCursor(strings.TrimSpace(req.URL.Query().Get("cursor")))
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid cursor: %v", err), http.StatusBadRequest)
		return
	}

	result, err := r.Conversations.ListMessageHistory(conversations.ListMessageHistoryParams{
		ConversationID: conversationID,
		Cursor:         cursor,
		PageSize:       pageSize,
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("list conversation messages failed: %v", err), http.StatusInternalServerError)
		return
	}

	hasPendingUpdate := false
	if _, found, err := r.Conversations.GetLatestPendingMessageByConversationID(conversationID); err != nil {
		http.Error(w, fmt.Sprintf("check pending update failed: %v", err), http.StatusInternalServerError)
		return
	} else if found {
		hasPendingUpdate = true
	}

	response := conversationMessagesResponse{
		Conversation: conversationResponse{
			ID:               conversation.ID,
			Handle:           conversation.DisplayHandle,
			AgentProfileName: conversation.AgentProfileName,
			AgentBackend:     conversation.AgentBackend,
			WorkingDirectory: conversation.WorkingDirectory,
			Status:           conversation.Status,
			UpdatedAt:        conversation.UpdatedAt.UTC(),
			PreviewText:      conversation.PreviewText,
			HasPendingUpdate: hasPendingUpdate,
		},
		Messages: result.Messages,
	}
	if result.NextCursor != nil {
		encodedCursor, err := encodeMessageHistoryCursor(*result.NextCursor)
		if err != nil {
			http.Error(w, fmt.Sprintf("encode cursor failed: %v", err), http.StatusInternalServerError)
			return
		}
		response.NextCursor = encodedCursor
	}

	writeJSON(w, http.StatusOK, response)
}

func (r Routes) createAgentProfile(w http.ResponseWriter, req *http.Request) {
	var profile tincanconfig.AgentProfile
	if err := decodeJSONBody(req, &profile); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if _, ok := r.Backends.Get(profile.AgentBackend); !ok {
		http.Error(w, fmt.Sprintf("unknown agent backend %q", profile.AgentBackend), http.StatusBadRequest)
		return
	}

	created, err := r.Profiles.Create(profile)
	if err != nil {
		writeConfigMutationError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"profile": created})
}

func (r Routes) updateAgentProfile(w http.ResponseWriter, req *http.Request, name string) {
	var profile tincanconfig.AgentProfile
	if err := decodeJSONBody(req, &profile); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if _, ok := r.Backends.Get(profile.AgentBackend); !ok {
		http.Error(w, fmt.Sprintf("unknown agent backend %q", profile.AgentBackend), http.StatusBadRequest)
		return
	}

	updated, err := r.Profiles.Update(name, profile)
	if err != nil {
		writeConfigMutationError(w, err)
		return
	}
	if _, err := r.syncRouterProfile(name, updated.Name); err != nil {
		writeConfigMutationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"profile": updated})
}

func (r Routes) deleteAgentProfile(w http.ResponseWriter, req *http.Request, name string) {
	if err := r.Profiles.Delete(name); err != nil {
		writeConfigMutationError(w, err)
		return
	}
	if _, err := r.syncRouterProfile(name, ""); err != nil {
		writeConfigMutationError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (r Routes) createAgentBackend(w http.ResponseWriter, req *http.Request) {
	body, backend, err := decodeBackendUpsertRequest(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := r.validateBackendDefinition(body.Name, backend); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	created, err := r.Backends.Create(body.Name, backend)
	if err != nil {
		writeConfigMutationError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"backend": backendResponse{Name: body.Name, Type: created.Type, Options: created.Options},
	})
}

func (r Routes) updateAgentBackend(w http.ResponseWriter, req *http.Request, name string) {
	body, backend, err := decodeBackendUpsertRequest(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.Name) != strings.TrimSpace(name) {
		http.Error(w, "agent backend name in body must match request path", http.StatusBadRequest)
		return
	}
	if err := r.validateBackendDefinition(name, backend); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	updated, err := r.Backends.Update(name, backend)
	if err != nil {
		writeConfigMutationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"backend": backendResponse{Name: name, Type: updated.Type, Options: updated.Options},
	})
}

func (r Routes) deleteAgentBackend(w http.ResponseWriter, req *http.Request, name string) {
	for _, profile := range r.Profiles.List() {
		if profile.AgentBackend == name {
			http.Error(w, fmt.Sprintf("agent backend %q is still referenced by profile %q", name, profile.Name), http.StatusConflict)
			return
		}
	}
	if err := r.Backends.Delete(name); err != nil {
		writeConfigMutationError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (r Routes) validateBackendDefinition(name string, backend tincanconfig.AgentBackendDefinition) error {
	adapter, ok := r.Adapters[backend.Type]
	if !ok {
		return fmt.Errorf("unknown backend type %q", backend.Type)
	}
	return adapter.ValidateBackend(name, backend)
}

func (r Routes) syncRouterProfile(currentName string, nextName string) (bool, error) {
	if r.AppConfig == nil {
		return false, nil
	}
	return r.AppConfig.UpdateRouterProfileReference(currentName, nextName)
}

func encodeConversationSummaryCursor(cursor conversations.ConversationSummaryCursor) (string, error) {
	payload, err := json.Marshal(cursor)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(payload), nil
}

func decodeConversationSummaryCursor(raw string) (*conversations.ConversationSummaryCursor, error) {
	if raw == "" {
		return nil, nil
	}

	payload, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, err
	}

	var cursor conversations.ConversationSummaryCursor
	if err := json.Unmarshal(payload, &cursor); err != nil {
		return nil, err
	}
	if cursor.UpdatedAt.IsZero() || strings.TrimSpace(cursor.ID) == "" {
		return nil, fmt.Errorf("cursor must include updated_at and id")
	}
	return &cursor, nil
}

func encodeMessageHistoryCursor(cursor conversations.MessageHistoryCursor) (string, error) {
	payload, err := json.Marshal(cursor)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(payload), nil
}

func decodeMessageHistoryCursor(raw string) (*conversations.MessageHistoryCursor, error) {
	if raw == "" {
		return nil, nil
	}

	payload, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, err
	}

	var cursor conversations.MessageHistoryCursor
	if err := json.Unmarshal(payload, &cursor); err != nil {
		return nil, err
	}
	if cursor.CreatedAt.IsZero() || strings.TrimSpace(cursor.ID) == "" {
		return nil, fmt.Errorf("cursor must include created_at and id")
	}
	return &cursor, nil
}

func decodeJSONBody(req *http.Request, target any) error {
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("invalid json body: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != nil && err != io.EOF {
		return fmt.Errorf("invalid json body: body must contain exactly one JSON value")
	}
	return nil
}

func decodeBackendUpsertRequest(req *http.Request) (backendUpsertRequest, tincanconfig.AgentBackendDefinition, error) {
	var body backendUpsertRequest
	if err := decodeJSONBody(req, &body); err != nil {
		return backendUpsertRequest{}, tincanconfig.AgentBackendDefinition{}, err
	}
	return body, tincanconfig.AgentBackendDefinition{
		Type:    body.Type,
		Options: body.Options,
	}, nil
}

func writeConfigMutationError(w http.ResponseWriter, err error) {
	status := http.StatusBadRequest
	if strings.Contains(err.Error(), "not found") {
		status = http.StatusNotFound
	}
	http.Error(w, err.Error(), status)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write api json failed: %v", err)
	}
}
