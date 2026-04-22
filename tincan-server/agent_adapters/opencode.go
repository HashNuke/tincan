package agent_adapters

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os/exec"
	"sort"
	"strings"

	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

type OpencodeAdapter struct {
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
	Model *openCodeModelRef    `json:"model,omitempty"`
	Agent string               `json:"agent,omitempty"`
	Parts []openCodePromptPart `json:"parts"`
}

type openCodeMessageResponse struct {
	Parts []openCodeResponsePart `json:"parts"`
}

type openCodeResponsePart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

func (a *OpencodeAdapter) Backend() string {
	return "opencode"
}

func (a *OpencodeAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	if backend.Options.ConnectionType == "" {
		return fmt.Errorf("agent backend %q requires options.connection_type for opencode", name)
	}
	if backend.Options.ConnectionType == "server" && backend.Options.BaseURL == "" {
		return fmt.Errorf("agent backend %q requires options.base_url when connection_type=server", name)
	}
	return nil
}

func (a *OpencodeAdapter) SupportsModelDiscovery() bool {
	return true
}

func (a *OpencodeAdapter) ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error) {
	command := exec.Command("opencode", "models")
	output, err := command.CombinedOutput()
	if err != nil {
		trimmedOutput := strings.TrimSpace(string(output))
		if trimmedOutput == "" {
			return nil, fmt.Errorf("run opencode models: %w", err)
		}
		return nil, fmt.Errorf("run opencode models: %w: %s", err, trimmedOutput)
	}

	models := parseOpenCodeModelsOutput(string(output))
	if len(models) == 0 {
		return nil, fmt.Errorf("opencode models returned no models")
	}
	return models, nil
}

func (a *OpencodeAdapter) StartConversation(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, title string, message string) (ConversationStartResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return ConversationStartResult{}, err
	}
	if title == "" {
		return ConversationStartResult{}, fmt.Errorf("start conversation requires non-empty title")
	}
	if message == "" {
		return ConversationStartResult{}, fmt.Errorf("start conversation requires non-empty message")
	}

	httpClient := a.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return ConversationStartResult{}, fmt.Errorf("parse opencode base url: %w", err)
	}

	session, err := a.createSession(httpClient, *baseURL, profile.WorkingDirectory, title)
	if err != nil {
		return ConversationStartResult{}, err
	}
	log.Printf(
		"opencode session created: session_id=%q directory=%q title=%q",
		session.ID,
		profile.WorkingDirectory,
		title,
	)

	promptURL := *baseURL
	promptURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session/" + session.ID + "/prompt_async"
	query := promptURL.Query()
	query.Set("directory", profile.WorkingDirectory)
	promptURL.RawQuery = query.Encode()

	modelRef, err := parseOptionalOpenCodeModel(backend.Options.Model)
	if err != nil {
		return ConversationStartResult{}, err
	}

	promptBody, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: backend.Options.Agent,
		Parts: []openCodePromptPart{{Type: "text", Text: message}},
	})
	if err != nil {
		return ConversationStartResult{}, fmt.Errorf("marshal prompt request: %w", err)
	}

	promptReq, err := http.NewRequest(http.MethodPost, promptURL.String(), bytes.NewReader(promptBody))
	if err != nil {
		return ConversationStartResult{}, fmt.Errorf("build prompt request: %w", err)
	}
	promptReq.Header.Set("Content-Type", "application/json")

	promptResp, err := httpClient.Do(promptReq)
	if err != nil {
		return ConversationStartResult{}, fmt.Errorf("opencode prompt_async request failed: %w", err)
	}
	defer promptResp.Body.Close()

	if promptResp.StatusCode != http.StatusNoContent {
		return ConversationStartResult{}, fmt.Errorf("opencode prompt_async failed with status %d", promptResp.StatusCode)
	}
	log.Printf(
		"opencode prompt scheduled: session_id=%q directory=%q agent=%q model=%q",
		session.ID,
		profile.WorkingDirectory,
		backend.Options.Agent,
		backend.Options.Model,
	)

	return ConversationStartResult{
		BackendConversationID: session.ID,
		Status:                "running",
	}, nil
}

func (a *OpencodeAdapter) ContinueConversation(conversation conversations.Conversation, backend tincanconfig.AgentBackendDefinition, message string) error {
	if err := a.ValidateBackend(conversation.AgentBackend, backend); err != nil {
		return err
	}
	if message == "" {
		return fmt.Errorf("continue conversation requires non-empty message")
	}

	httpClient := a.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return fmt.Errorf("parse opencode base url: %w", err)
	}

	promptURL := *baseURL
	promptURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session/" + conversation.BackendConversationID + "/prompt_async"
	query := promptURL.Query()
	query.Set("directory", conversation.WorkingDirectory)
	promptURL.RawQuery = query.Encode()

	modelRef, err := parseOptionalOpenCodeModel(backend.Options.Model)
	if err != nil {
		return err
	}

	promptBody, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: backend.Options.Agent,
		Parts: []openCodePromptPart{{Type: "text", Text: message}},
	})
	if err != nil {
		return fmt.Errorf("marshal continue prompt request: %w", err)
	}

	promptReq, err := http.NewRequest(http.MethodPost, promptURL.String(), bytes.NewReader(promptBody))
	if err != nil {
		return fmt.Errorf("build continue prompt request: %w", err)
	}
	promptReq.Header.Set("Content-Type", "application/json")

	promptResp, err := httpClient.Do(promptReq)
	if err != nil {
		return fmt.Errorf("opencode continue prompt_async request failed: %w", err)
	}
	defer promptResp.Body.Close()

	if promptResp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("opencode continue prompt_async failed with status %d", promptResp.StatusCode)
	}
	log.Printf(
		"opencode continuation scheduled: session_id=%q directory=%q agent=%q model=%q",
		conversation.BackendConversationID,
		conversation.WorkingDirectory,
		backend.Options.Agent,
		backend.Options.Model,
	)
	return nil
}

func (a *OpencodeAdapter) RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt string, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}

	raw, err := a.runMessagePrompt(backend, profile.WorkingDirectory, "Router", prompt)
	if err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}
	if raw == "" {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("router returned empty response")
	}

	var result tincanrouter.RouteUserInputResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("decode router json response: %w; raw=%s", err, raw)
	}
	if result.Action == "" {
		return tincanrouter.RouteUserInputResult{}, fmt.Errorf("router response missing action")
	}
	return result, nil
}

func (a *OpencodeAdapter) RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt string, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}

	raw, err := a.runMessagePrompt(backend, profile.WorkingDirectory, "Update processor", prompt)
	if err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}
	if raw == "" {
		return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("conversation update processor returned empty response")
	}

	var result tincanrouter.ProcessConversationUpdateResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, fmt.Errorf("decode conversation update processor json response: %w; raw=%s", err, raw)
	}
	return result, nil
}

func (a *OpencodeAdapter) runMessagePrompt(backend tincanconfig.AgentBackendDefinition, workingDirectory string, title string, prompt string) (string, error) {
	httpClient := a.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return "", fmt.Errorf("parse opencode base url: %w", err)
	}

	session, err := a.createSession(httpClient, *baseURL, workingDirectory, title)
	if err != nil {
		return "", err
	}

	messageURL := baseURL.ResolveReference(&url.URL{Path: strings.TrimRight(baseURL.Path, "/") + "/session/" + session.ID + "/message"})
	query := messageURL.Query()
	query.Set("directory", workingDirectory)
	messageURL.RawQuery = query.Encode()

	modelRef, err := parseOptionalOpenCodeModel(backend.Options.Model)
	if err != nil {
		return "", err
	}

	body, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: backend.Options.Agent,
		Parts: []openCodePromptPart{{Type: "text", Text: prompt}},
	})
	if err != nil {
		return "", fmt.Errorf("marshal prompt request: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, messageURL.String(), bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build prompt request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("prompt request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("prompt request failed with status %d", resp.StatusCode)
	}

	var messageResponse openCodeMessageResponse
	if err := json.NewDecoder(resp.Body).Decode(&messageResponse); err != nil {
		return "", fmt.Errorf("decode prompt response: %w", err)
	}

	var textBuilder strings.Builder
	for _, part := range messageResponse.Parts {
		if part.Type == "text" {
			textBuilder.WriteString(part.Text)
		}
	}

	return strings.TrimSpace(textBuilder.String()), nil
}

func (a *OpencodeAdapter) createSession(httpClient *http.Client, baseURL url.URL, directory string, title string) (openCodeSession, error) {
	createSessionURL := baseURL
	createSessionURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session"
	query := createSessionURL.Query()
	query.Set("directory", directory)
	createSessionURL.RawQuery = query.Encode()

	createBody, err := json.Marshal(openCodeCreateSessionRequest{Title: title})
	if err != nil {
		return openCodeSession{}, fmt.Errorf("marshal create session request: %w", err)
	}

	createReq, err := http.NewRequest(http.MethodPost, createSessionURL.String(), bytes.NewReader(createBody))
	if err != nil {
		return openCodeSession{}, fmt.Errorf("build create session request: %w", err)
	}
	createReq.Header.Set("Content-Type", "application/json")

	createResp, err := httpClient.Do(createReq)
	if err != nil {
		return openCodeSession{}, fmt.Errorf("create opencode session request failed: %w", err)
	}
	defer createResp.Body.Close()

	if createResp.StatusCode != http.StatusOK {
		return openCodeSession{}, fmt.Errorf("create opencode session failed with status %d", createResp.StatusCode)
	}

	var session openCodeSession
	if err := json.NewDecoder(createResp.Body).Decode(&session); err != nil {
		return openCodeSession{}, fmt.Errorf("decode opencode session response: %w", err)
	}
	if session.ID == "" {
		return openCodeSession{}, fmt.Errorf("opencode session response missing id")
	}
	return session, nil
}

func parseOptionalOpenCodeModel(raw string) (*openCodeModelRef, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	parts := strings.SplitN(raw, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, fmt.Errorf("expected opencode model in provider/model form")
	}
	return &openCodeModelRef{ProviderID: parts[0], ModelID: parts[1]}, nil
}

func parseOpenCodeModelsOutput(raw string) []string {
	seen := make(map[string]struct{})
	models := make([]string, 0)

	for _, line := range strings.Split(raw, "\n") {
		for _, field := range strings.Fields(strings.TrimSpace(line)) {
			if !looksLikeOpenCodeModel(field) {
				continue
			}
			if _, exists := seen[field]; exists {
				continue
			}
			seen[field] = struct{}{}
			models = append(models, field)
		}
	}

	sort.Strings(models)
	return models
}

func looksLikeOpenCodeModel(value string) bool {
	if value == "provider/model" {
		return false
	}
	if strings.Contains(value, "://") {
		return false
	}

	slashIndex := strings.Index(value, "/")
	if slashIndex <= 0 || slashIndex == len(value)-1 {
		return false
	}

	providerID := strings.TrimSpace(value[:slashIndex])
	modelID := strings.TrimSpace(value[slashIndex+1:])
	if providerID == "" || modelID == "" {
		return false
	}
	return true
}
