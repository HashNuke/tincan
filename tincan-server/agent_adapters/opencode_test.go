package agent_adapters

import (
	"strings"
	"testing"

	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
)

func TestParseOptionalOpenCodeModelAllowsEmptyString(t *testing.T) {
	model, err := parseOptionalOpenCodeModel("")
	if err != nil {
		t.Fatalf("parseOptionalOpenCodeModel returned error: %v", err)
	}
	if model != nil {
		t.Fatalf("expected nil model for empty input, got %#v", model)
	}
}

func TestParseOptionalOpenCodeModelParsesProviderAndModel(t *testing.T) {
	model, err := parseOptionalOpenCodeModel("openai/gpt-5")
	if err != nil {
		t.Fatalf("parseOptionalOpenCodeModel returned error: %v", err)
	}
	if model == nil {
		t.Fatalf("expected parsed model")
	}
	if model.ProviderID != "openai" || model.ModelID != "gpt-5" {
		t.Fatalf("unexpected parsed model: %#v", model)
	}
}

func TestParseOptionalOpenCodeModelPreservesNestedModelPath(t *testing.T) {
	model, err := parseOptionalOpenCodeModel("openrouter/openai/gpt-5")
	if err != nil {
		t.Fatalf("parseOptionalOpenCodeModel returned error: %v", err)
	}
	if model == nil {
		t.Fatalf("expected parsed model")
	}
	if model.ProviderID != "openrouter" || model.ModelID != "openai/gpt-5" {
		t.Fatalf("unexpected parsed model: %#v", model)
	}
}

func TestParseOptionalOpenCodeModelRejectsInvalidFormat(t *testing.T) {
	if _, err := parseOptionalOpenCodeModel("gpt-5"); err == nil {
		t.Fatalf("expected invalid model format to fail")
	}
}

func TestParseOpenCodeModelsOutputExtractsModels(t *testing.T) {
	raw := `
openai/gpt-5.3-codex-spark
anthropic/claude-sonnet-4
`

	models := parseOpenCodeModelsOutput(raw)
	if len(models) != 2 {
		t.Fatalf("expected 2 models, got %d (%v)", len(models), models)
	}
	if models[0] != "anthropic/claude-sonnet-4" || models[1] != "openai/gpt-5.3-codex-spark" {
		t.Fatalf("unexpected models: %v", models)
	}
}

func TestParseOpenCodeModelsOutputIgnoresNoise(t *testing.T) {
	raw := `
	Available models
	provider/model
	openai/gpt-5.3-codex-spark $0.30
	openrouter/openai/gpt-5
	https://example.com/not-a-model
	`

	models := parseOpenCodeModelsOutput(raw)
	if len(models) != 2 {
		t.Fatalf("expected 2 parsed models, got %d (%v)", len(models), models)
	}
	if models[0] != "openai/gpt-5.3-codex-spark" || models[1] != "openrouter/openai/gpt-5" {
		t.Fatalf("unexpected parsed models: %v", models)
	}
}

func TestBuildConversationCommandForNewConversation(t *testing.T) {
	adapter := &OpencodeAdapter{}
	command, err := adapter.BuildConversationCommand(ConversationCommandInput{
		Conversation: conversations.Conversation{
			AgentBackend:     "opencode-1",
			WorkingDirectory: "/tmp/project",
		},
		Backend: tincanconfig.AgentBackendDefinition{
			Type: "opencode",
			Options: tincanconfig.AgentBackendOptions{
				ConnectionType: "command",
				Model:          "openai/gpt-5.3-codex-spark",
				ModelVariant:   "medium",
				Agent:          "build",
				ExtraArgs:      []string{"--share"},
			},
		},
		Title: "Build fixes",
		Inputs: []conversations.ConversationInput{{
			UserText: "Fix the failing build.",
		}},
	})
	if err != nil {
		t.Fatalf("BuildConversationCommand returned error: %v", err)
	}

	if command.Program != "opencode" {
		t.Fatalf("unexpected program: %q", command.Program)
	}
	if !strings.Contains(strings.Join(command.Args, " "), "--title Build fixes") {
		t.Fatalf("expected title args, got %v", command.Args)
	}
	if !strings.Contains(strings.Join(command.Args, " "), "--dir /tmp/project") {
		t.Fatalf("expected dir args, got %v", command.Args)
	}
	if strings.TrimSpace(command.Stdin) != "Fix the failing build." {
		t.Fatalf("unexpected stdin: %q", command.Stdin)
	}
}

func TestBuildConversationCommandBatchesQueuedFollowUps(t *testing.T) {
	adapter := &OpencodeAdapter{}
	command, err := adapter.BuildConversationCommand(ConversationCommandInput{
		Conversation: conversations.Conversation{
			AgentBackend:          "opencode-1",
			WorkingDirectory:      "/tmp/project",
			BackendConversationID: "sess-123",
		},
		Backend: tincanconfig.AgentBackendDefinition{
			Type: "opencode",
			Options: tincanconfig.AgentBackendOptions{
				ConnectionType: "command",
			},
		},
		Inputs: []conversations.ConversationInput{
			{UserText: "First update."},
			{UserText: "Second update."},
		},
	})
	if err != nil {
		t.Fatalf("BuildConversationCommand returned error: %v", err)
	}

	if !strings.Contains(strings.Join(command.Args, " "), "--session sess-123") {
		t.Fatalf("expected session args, got %v", command.Args)
	}
	if !strings.Contains(command.Stdin, "1. First update.") || !strings.Contains(command.Stdin, "2. Second update.") {
		t.Fatalf("expected numbered batch prompt, got %q", command.Stdin)
	}
}

func TestParseOpenCodeRunJSONOutputCollectsCompletedText(t *testing.T) {
	raw := []byte(`
{"type":"tool_use","part":{"type":"tool"}}
{"type":"text","part":{"type":"text","text":"{\"action\":\"ignore\""}}
{"type":"text","part":{"type":"text","text":"}"}}
`)

	text, err := parseOpenCodeRunJSONOutput(raw)
	if err != nil {
		t.Fatalf("parseOpenCodeRunJSONOutput returned error: %v", err)
	}
	if text != `{"action":"ignore"}` {
		t.Fatalf("unexpected parsed text: %q", text)
	}
}
