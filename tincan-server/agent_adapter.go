package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

)

type AgentAdapter interface {
	Backend() string
	ValidateProfile(profile AgentProfile) error
	StartConversation(profile AgentProfile, title string, message string) (AgentConversationStartResult, error)
}

type AgentConversationStartResult struct {
	BackendConversationID string
	Status                string
}

type OpenCodeServerAdapter struct {
	httpClient *http.Client
}

type openCodeCreateSessionRequest struct {
	Title string `json:"title"`
}

type openCodeSession struct {
	ID string `json:"id"`
}

type openCodeModelRef struct {
	ProviderID string `json:"providerID"`
	ModelID    string `json:"modelID"`
}

type openCodePromptPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type openCodePromptAsyncRequest struct {
	Model *openCodeModelRef   `json:"model,omitempty"`
	Agent string              `json:"agent,omitempty"`
	Parts []openCodePromptPart `json:"parts"`
}

func (a *OpenCodeServerAdapter) Backend() string {
	return "opencode-server"
}

func (a *OpenCodeServerAdapter) ValidateProfile(profile AgentProfile) error {
	if profile.AgentBackendOptions.BaseURL == "" {
		return fmt.Errorf("profile %q requires agent_backend_options.base_url for opencode-server", profile.Name)
	}
	return nil
}

func (a *OpenCodeServerAdapter) StartConversation(profile AgentProfile, title string, message string) (AgentConversationStartResult, error) {
	if err := a.ValidateProfile(profile); err != nil {
		return AgentConversationStartResult{}, err
	}
	if title == "" {
		return AgentConversationStartResult{}, fmt.Errorf("start conversation requires non-empty title")
	}
	if message == "" {
		return AgentConversationStartResult{}, fmt.Errorf("start conversation requires non-empty message")
	}

	httpClient := a.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	baseURL, err := url.Parse(profile.AgentBackendOptions.BaseURL)
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("parse opencode base url: %w", err)
	}

	createSessionURL := *baseURL
	createSessionURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session"
	query := createSessionURL.Query()
	query.Set("directory", profile.WorkingDirectory)
	createSessionURL.RawQuery = query.Encode()

	createBody, err := json.Marshal(openCodeCreateSessionRequest{Title: title})
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("marshal create session request: %w", err)
	}

	createReq, err := http.NewRequest(http.MethodPost, createSessionURL.String(), bytes.NewReader(createBody))
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("build create session request: %w", err)
	}
	createReq.Header.Set("Content-Type", "application/json")

	createResp, err := httpClient.Do(createReq)
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("create opencode session request failed: %w", err)
	}
	defer createResp.Body.Close()

	if createResp.StatusCode != http.StatusOK {
		return AgentConversationStartResult{}, fmt.Errorf("create opencode session failed with status %d", createResp.StatusCode)
	}

	var session openCodeSession
	if err := json.NewDecoder(createResp.Body).Decode(&session); err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("decode opencode session response: %w", err)
	}
	if session.ID == "" {
		return AgentConversationStartResult{}, fmt.Errorf("opencode session response missing id")
	}

	promptURL := *baseURL
	promptURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session/" + session.ID + "/prompt_async"
	query = promptURL.Query()
	query.Set("directory", profile.WorkingDirectory)
	promptURL.RawQuery = query.Encode()

	modelRef, err := parseOpenCodeModel(profile.AgentBackendOptions.Model)
	if err != nil {
		return AgentConversationStartResult{}, err
	}

	promptBody, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: profile.AgentBackendOptions.Agent,
		Parts: []openCodePromptPart{{Type: "text", Text: message}},
	})
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("marshal prompt request: %w", err)
	}

	promptReq, err := http.NewRequest(http.MethodPost, promptURL.String(), bytes.NewReader(promptBody))
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("build prompt request: %w", err)
	}
	promptReq.Header.Set("Content-Type", "application/json")

	promptResp, err := httpClient.Do(promptReq)
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("opencode prompt_async request failed: %w", err)
	}
	defer promptResp.Body.Close()

	if promptResp.StatusCode != http.StatusNoContent {
		return AgentConversationStartResult{}, fmt.Errorf("opencode prompt_async failed with status %d", promptResp.StatusCode)
	}

	return AgentConversationStartResult{
		BackendConversationID: session.ID,
		Status:                "running",
	}, nil
}

func parseOpenCodeModel(raw string) (*openCodeModelRef, error) {
	parts := strings.SplitN(raw, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, fmt.Errorf("expected opencode model in provider/model form")
	}
	return &openCodeModelRef{ProviderID: parts[0], ModelID: parts[1]}, nil
}

func DefaultAgentAdapters() map[string]AgentAdapter {
	return map[string]AgentAdapter{
		"opencode-server": &OpenCodeServerAdapter{httpClient: http.DefaultClient},
	}
}
