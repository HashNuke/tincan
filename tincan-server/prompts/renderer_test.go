package prompts

import (
	"strings"
	"testing"
)

func TestRenderRouterUserPrompt(t *testing.T) {
	prompt, err := RenderRouterUserPrompt(RouterUserPromptData{
		RouterProfileName:            "Atlas",
		DefinedAgentProfiles:         []string{"Atlas", "Emma"},
		KnownConversationHandles:     []string{"emma#10"},
		CurrentConversationHandle:    "atlas#1",
		CurrentConversationNotes:     "Current notes",
		PendingUpdateHandles:         []string{"emma#10"},
		UnresolvedClarificationLines: []string{"assistant: Which Emma?"},
		UserTranscript:               "Atlas, do the signing fix",
	})
	if err != nil {
		t.Fatalf("RenderRouterUserPrompt: %v", err)
	}

	requiredSnippets := []string{
		"You are Atlas. You are a router for Tincan agents.",
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

	for _, snippet := range requiredSnippets {
		if !strings.Contains(prompt, snippet) {
			t.Fatalf("expected prompt to contain %q, got %q", snippet, prompt)
		}
	}
}

func TestRenderConversationUpdatePrompt(t *testing.T) {
	prompt, err := RenderConversationUpdatePrompt(ConversationUpdatePromptData{
		ConversationHandle: "emma#10",
		DetailText:         "I fixed the build and need approval to merge.",
	})
	if err != nil {
		t.Fatalf("RenderConversationUpdatePrompt: %v", err)
	}

	requiredSnippets := []string{
		"You are the Tincan conversation update processor.",
		"Conversation handle:\nemma#10",
		"Full update:\nI fixed the build and need approval to merge.",
	}

	for _, snippet := range requiredSnippets {
		if !strings.Contains(prompt, snippet) {
			t.Fatalf("expected prompt to contain %q, got %q", snippet, prompt)
		}
	}
}
