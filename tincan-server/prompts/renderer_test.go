package prompts

import (
	"strings"
	"testing"
)

func TestRenderRouterUserPrompt(t *testing.T) {
	data := RouterUserPromptData{
		RouterProfileName:            "Atlas",
		DefinedAgentProfiles:         []string{"Atlas", "Emma", "Hercules"},
		KnownConversationHandles:     []string{"emma#10"},
		CurrentConversationHandle:    "atlas#1",
		CurrentConversationNotes:     "Current notes",
		PendingUpdateHandles:         []string{"emma#10"},
		UnresolvedClarificationLines: []string{"assistant: Which Emma?"},
		UserTranscript:               "Atlas, do the signing fix",
	}

	systemPrompt, err := RenderRouterUserSystemPrompt(data)
	if err != nil {
		t.Fatalf("RenderRouterUserSystemPrompt: %v", err)
	}
	prompt, err := RenderRouterUserPrompt(data)
	if err != nil {
		t.Fatalf("RenderRouterUserPrompt: %v", err)
	}

	requiredSystemSnippets := []string{
		"You are Atlas. You are a router for Tincan agents.",
		"Allowed actions:",
		"Per-action fields:",
		`"action": string`,
		`"Emma, do the iOS signing fix" => action=new_conversation, agent_profile="Emma", message="do the iOS signing fix"`,
		`"Atlas, ask Hercules to run the date command" => action=new_conversation, agent_profile="Hercules", message="run the date command"`,
		`"Atlas, what do you have from hercules#4" => action=read_conversation_update, conversation_handle="hercules#4"`,
	}
	for _, snippet := range requiredSystemSnippets {
		if !strings.Contains(systemPrompt, snippet) {
			t.Fatalf("expected system prompt to contain %q, got %q", snippet, systemPrompt)
		}
	}

	requiredUserSnippets := []string{
		"Routing context below.",
		"### Defined agent profiles",
		"- Atlas",
		"- Emma",
		"- Hercules",
		"### Known conversation handles",
		"- emma#10",
		"Current conversation handle: atlas#1",
		"## Unresolved clarification history for current conversation",
		"- assistant: Which Emma?",
		"Latest user transcript\nAtlas, do the signing fix",
	}
	for _, snippet := range requiredUserSnippets {
		if !strings.Contains(prompt, snippet) {
			t.Fatalf("expected user prompt to contain %q, got %q", snippet, prompt)
		}
	}
}

func TestRenderConversationUpdatePrompt(t *testing.T) {
	data := ConversationUpdatePromptData{
		ConversationHandle: "emma#10",
		DetailText:         "I fixed the build and need approval to merge.",
	}

	systemPrompt, err := RenderConversationUpdateSystemPrompt(data)
	if err != nil {
		t.Fatalf("RenderConversationUpdateSystemPrompt: %v", err)
	}
	prompt, err := RenderConversationUpdatePrompt(data)
	if err != nil {
		t.Fatalf("RenderConversationUpdatePrompt: %v", err)
	}

	requiredSystemSnippets := []string{
		"Your job is to turn a full agent message into two short audio-friendly strings.",
		`"notification_text": string`,
		"Return valid JSON only.",
	}
	for _, snippet := range requiredSystemSnippets {
		if !strings.Contains(systemPrompt, snippet) {
			t.Fatalf("expected system prompt to contain %q, got %q", snippet, systemPrompt)
		}
	}

	requiredUserSnippets := []string{
		"**Conversation handle:** emma#10",
		"## Full update from the conversation",
		"I fixed the build and need approval to merge.",
	}

	for _, snippet := range requiredUserSnippets {
		if !strings.Contains(prompt, snippet) {
			t.Fatalf("expected user prompt to contain %q, got %q", snippet, prompt)
		}
	}
}
