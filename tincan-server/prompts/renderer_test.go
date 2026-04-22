package prompts

import (
	"strings"
	"testing"
)

func TestRenderRouterUserPrompt(t *testing.T) {
	data := RouterUserPromptData{
		RouterProfileName:            "Atlas",
		DefinedAgentProfiles:         []string{"Atlas", "Emma"},
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
		`"action": string`,
		`"Emma, do the iOS signing fix" => action=new_conversation, agent_profile="Emma", message="do the iOS signing fix"`,
	}
	for _, snippet := range requiredSystemSnippets {
		if !strings.Contains(systemPrompt, snippet) {
			t.Fatalf("expected system prompt to contain %q, got %q", snippet, systemPrompt)
		}
	}

	requiredUserSnippets := []string{
		"Routing context:",
		"Defined agent profiles:",
		"- Atlas",
		"- Emma",
		"Known conversation handles:",
		"- emma#10",
		"Current conversation handle:\natlas#1",
		"Unresolved clarification history:",
		"- assistant: Which Emma?",
		"User transcript:\nAtlas, do the signing fix",
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
		"You are the Tincan conversation update processor.",
		`"notification_text": string`,
		"Return valid JSON only.",
	}
	for _, snippet := range requiredSystemSnippets {
		if !strings.Contains(systemPrompt, snippet) {
			t.Fatalf("expected system prompt to contain %q, got %q", snippet, systemPrompt)
		}
	}

	requiredUserSnippets := []string{
		"Conversation handle:\nemma#10",
		"Full update:\nI fixed the build and need approval to merge.",
	}

	for _, snippet := range requiredUserSnippets {
		if !strings.Contains(prompt, snippet) {
			t.Fatalf("expected user prompt to contain %q, got %q", snippet, prompt)
		}
	}
}
