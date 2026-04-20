package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
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

func (a *OpencodeAdapter) ValidateBackend(name string, backend AgentBackendDefinition) error {
	if backend.Options.ConnectionType == "" {
		return fmt.Errorf("agent backend %q requires options.connection_type for opencode", name)
	}
	if backend.Options.ConnectionType == "server" && backend.Options.BaseURL == "" {
		return fmt.Errorf("agent backend %q requires options.base_url when connection_type=server", name)
	}
	return nil
}

func (a *OpencodeAdapter) StartConversation(profile AgentProfile, backend AgentBackendDefinition, title string, message string) (AgentConversationStartResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
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

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return AgentConversationStartResult{}, fmt.Errorf("parse opencode base url: %w", err)
	}

	session, err := a.createSession(httpClient, *baseURL, profile.WorkingDirectory, title)
	if err != nil {
		return AgentConversationStartResult{}, err
	}

	promptURL := *baseURL
	promptURL.Path = strings.TrimRight(baseURL.Path, "/") + "/session/" + session.ID + "/prompt_async"
	query := promptURL.Query()
	query.Set("directory", profile.WorkingDirectory)
	promptURL.RawQuery = query.Encode()

	modelRef, err := parseOpenCodeModel(backend.Options.Model)
	if err != nil {
		return AgentConversationStartResult{}, err
	}

	promptBody, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: backend.Options.Agent,
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

func (a *OpencodeAdapter) RouteUser(backend AgentBackendDefinition, input UserRouterInput) (UserRouterResult, error) {
	if err := a.ValidateBackend("__router__", backend); err != nil {
		return UserRouterResult{}, err
	}

	httpClient := a.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	baseURL, err := url.Parse(backend.Options.BaseURL)
	if err != nil {
		return UserRouterResult{}, fmt.Errorf("parse opencode base url: %w", err)
	}

	workingDirectory := "/Users/akash/code/apple/tincan"
	session, err := a.createSession(httpClient, *baseURL, workingDirectory, "Router")
	if err != nil {
		return UserRouterResult{}, err
	}

	messageURL := baseURL.ResolveReference(&url.URL{Path: strings.TrimRight(baseURL.Path, "/") + "/session/" + session.ID + "/message"})
	query := messageURL.Query()
	query.Set("directory", workingDirectory)
	messageURL.RawQuery = query.Encode()

	modelRef, err := parseOpenCodeModel(backend.Options.Model)
	if err != nil {
		return UserRouterResult{}, err
	}

	prompt := buildUserRouterPrompt(input)
	body, err := json.Marshal(openCodePromptAsyncRequest{
		Model: modelRef,
		Agent: backend.Options.Agent,
		Parts: []openCodePromptPart{{Type: "text", Text: prompt}},
	})
	if err != nil {
		return UserRouterResult{}, fmt.Errorf("marshal router prompt: %w", err)
	}

	req, err := http.NewRequest(http.MethodPost, messageURL.String(), bytes.NewReader(body))
	if err != nil {
		return UserRouterResult{}, fmt.Errorf("build router message request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return UserRouterResult{}, fmt.Errorf("router message request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return UserRouterResult{}, fmt.Errorf("router message failed with status %d", resp.StatusCode)
	}

	var messageResponse openCodeMessageResponse
	if err := json.NewDecoder(resp.Body).Decode(&messageResponse); err != nil {
		return UserRouterResult{}, fmt.Errorf("decode router response: %w", err)
	}

	var textBuilder strings.Builder
	for _, part := range messageResponse.Parts {
		if part.Type == "text" {
			textBuilder.WriteString(part.Text)
		}
	}

	raw := strings.TrimSpace(textBuilder.String())
	if raw == "" {
		return UserRouterResult{}, fmt.Errorf("router returned empty response")
	}

	var result UserRouterResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return UserRouterResult{}, fmt.Errorf("decode router json response: %w; raw=%s", err, raw)
	}
	if result.Action == "" {
		return UserRouterResult{}, fmt.Errorf("router response missing action")
	}
	result.RawTranscript = input.Transcript
	return result, nil
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

func parseOpenCodeModel(raw string) (*openCodeModelRef, error) {
	parts := strings.SplitN(raw, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return nil, fmt.Errorf("expected opencode model in provider/model form")
	}
	return &openCodeModelRef{ProviderID: parts[0], ModelID: parts[1]}, nil
}

func buildUserRouterPrompt(input UserRouterInput) string {
	return strings.TrimSpace(`You are the Tincan router. Decide what to do with the user's transcript.

Return JSON only. Do not wrap in markdown.

Allowed actions:
- new_conversation
- message
- read_conversation_update
- switch_context
- ask_clarifying_question
- ignore

Response schema:
{
  "action": string,
  "message": string,
  "agent": string,
  "conversation_handle": string,
  "conversation_title": string,
  "immediate_feedback": string,
  "raw_transcript": string
}

Rules:
- Only choose new_conversation when the user explicitly asks for a new chat/session/conversation.
- If ambiguous, use ask_clarifying_question.
- For now, if the transcript clearly addresses an existing handle like emma#12 use message.
- If no action should be taken, use ignore.
- conversation_title should be short and useful when action is new_conversation.

User transcript:
` + input.Transcript)
}
