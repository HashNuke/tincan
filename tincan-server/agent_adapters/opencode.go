package agent_adapters

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strings"

	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

type OpencodeAdapter struct{}

type openCodeModelRef struct {
	ProviderID string `json:"providerID"`
	ModelID    string `json:"modelID"`
}

type openCodeRunOutputPart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type openCodeRunOutputEvent struct {
	Type  string                `json:"type"`
	Part  openCodeRunOutputPart `json:"part"`
	Error any                   `json:"error,omitempty"`
}

func (a *OpencodeAdapter) Backend() string {
	return "opencode"
}

func (a *OpencodeAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	if backend.Options.ConnectionType == "" {
		return fmt.Errorf("agent backend %q requires options.connection_type for opencode", name)
	}
	if backend.Options.ConnectionType != "command" {
		return fmt.Errorf("agent backend %q requires options.connection_type=command for opencode", name)
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

func (a *OpencodeAdapter) BuildConversationCommand(input ConversationCommandInput) (ManagedCommand, error) {
	if err := a.ValidateBackend(input.Conversation.AgentBackend, input.Backend); err != nil {
		return ManagedCommand{}, err
	}
	if len(input.Inputs) == 0 {
		return ManagedCommand{}, fmt.Errorf("managed conversation command requires at least one input")
	}

	args := a.baseRunArgs(input.Backend, input.Conversation.WorkingDirectory)
	if strings.TrimSpace(input.Conversation.BackendConversationID) == "" {
		if trimmedTitle := strings.TrimSpace(input.Title); trimmedTitle != "" {
			args = append(args, "--title", trimmedTitle)
		}
	} else {
		args = append(args, "--session", input.Conversation.BackendConversationID)
	}

	return ManagedCommand{
		Program: "opencode",
		Args:    args,
		Stdin:   buildManagedConversationPrompt(input.Inputs),
	}, nil
}

func (a *OpencodeAdapter) RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.RouteUserInputResult{}, err
	}

	raw, err := a.runOneShotPrompt(backend, profile.WorkingDirectory, buildSyntheticPrompt(prompt))
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

func (a *OpencodeAdapter) RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	if err := a.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return tincanrouter.ProcessConversationUpdateResult{}, err
	}

	raw, err := a.runOneShotPrompt(backend, profile.WorkingDirectory, buildSyntheticPrompt(prompt))
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

func (a *OpencodeAdapter) baseRunArgs(backend tincanconfig.AgentBackendDefinition, workingDirectory string) []string {
	args := []string{"run", "--format", "json"}
	if strings.TrimSpace(workingDirectory) != "" {
		args = append(args, "--dir", workingDirectory)
	}
	if strings.TrimSpace(backend.Options.Model) != "" {
		args = append(args, "--model", backend.Options.Model)
	}
	if strings.TrimSpace(backend.Options.Agent) != "" {
		args = append(args, "--agent", backend.Options.Agent)
	}
	if strings.TrimSpace(backend.Options.ModelVariant) != "" {
		args = append(args, "--variant", backend.Options.ModelVariant)
	}
	args = append(args, backend.Options.ExtraArgs...)
	return args
}

func (a *OpencodeAdapter) runOneShotPrompt(backend tincanconfig.AgentBackendDefinition, workingDirectory string, stdin string) (string, error) {
	args := a.baseRunArgs(backend, workingDirectory)

	command := exec.Command("opencode", args...)
	command.Dir = workingDirectory
	command.Stdin = strings.NewReader(stdin)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		trimmedStderr := strings.TrimSpace(stderr.String())
		if trimmedStderr == "" {
			return "", fmt.Errorf("run opencode prompt: %w", err)
		}
		return "", fmt.Errorf("run opencode prompt: %w: %s", err, trimmedStderr)
	}

	text, err := parseOpenCodeRunJSONOutput(stdout.Bytes())
	if err != nil {
		trimmedStderr := strings.TrimSpace(stderr.String())
		if trimmedStderr == "" {
			return "", err
		}
		return "", fmt.Errorf("%w: %s", err, trimmedStderr)
	}
	return text, nil
}

func buildSyntheticPrompt(prompt Prompt) string {
	var builder strings.Builder
	systemPrompt := strings.TrimSpace(prompt.System)
	userPrompt := strings.TrimSpace(prompt.User)

	if systemPrompt != "" {
		builder.WriteString("Follow these instructions exactly.\n\n")
		builder.WriteString("<SYSTEM>\n")
		builder.WriteString(systemPrompt)
		builder.WriteString("\n</SYSTEM>\n\n")
	}
	if userPrompt != "" {
		builder.WriteString("<USER>\n")
		builder.WriteString(userPrompt)
		builder.WriteString("\n</USER>\n")
	}

	return strings.TrimSpace(builder.String())
}

func buildManagedConversationPrompt(inputs []conversations.ConversationInput) string {
	if len(inputs) == 0 {
		return ""
	}
	if len(inputs) == 1 {
		return strings.TrimSpace(inputs[0].UserText)
	}

	var builder strings.Builder
	builder.WriteString("The user sent these follow-up messages while you were already working in this same conversation. Continue the same session and address them in order.\n\n")
	for index, input := range inputs {
		builder.WriteString(fmt.Sprintf("%d. %s\n", index+1, strings.TrimSpace(input.UserText)))
	}
	return strings.TrimSpace(builder.String())
}

func parseOpenCodeRunJSONOutput(raw []byte) (string, error) {
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	var builder strings.Builder

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var event openCodeRunOutputEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			return "", fmt.Errorf("decode opencode json output: %w", err)
		}
		if event.Type != "text" || event.Part.Type != "text" {
			continue
		}
		builder.WriteString(event.Part.Text)
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("read opencode json output: %w", err)
	}

	return strings.TrimSpace(builder.String()), nil
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
