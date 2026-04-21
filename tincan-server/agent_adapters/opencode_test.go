package agent_adapters

import "testing"

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
