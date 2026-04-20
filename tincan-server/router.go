package main

import (
	"fmt"
	"regexp"
	"strings"
)

type Router struct {
	profiles *AgentProfileStore
}

type UserRouterInput struct {
	Transcript string
}

type UserRouterResult struct {
	Action            string `json:"action"`
	Message           string `json:"message,omitempty"`
	Agent             string `json:"agent,omitempty"`
	ConversationHandle string `json:"conversation_handle,omitempty"`
	ConversationTitle string `json:"conversation_title,omitempty"`
	ImmediateFeedback string `json:"immediate_feedback,omitempty"`
	RawTranscript     string `json:"raw_transcript"`
}

func NewRouter(profiles *AgentProfileStore) *Router {
	return &Router{profiles: profiles}
}

func (r *Router) RouteUserTranscript(input UserRouterInput) UserRouterResult {
	trimmed := strings.TrimSpace(input.Transcript)
	if trimmed == "" {
		return UserRouterResult{
			Action:            "ignore",
			ImmediateFeedback: "I didn't catch anything to send.",
			RawTranscript:     input.Transcript,
		}
	}

	lowered := strings.ToLower(trimmed)
	for _, profile := range r.profiles.List() {
		name := strings.ToLower(profile.Name)
		patterns := []string{
			"start a new " + name + " conversation",
			"new chat with " + name,
			"create a new " + name + " session",
		}

		matched := false
		for _, pattern := range patterns {
			if strings.Contains(lowered, pattern) {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}

		message := extractNewConversationMessage(trimmed)
		if message == "" {
			return UserRouterResult{
				Action:            "ask_clarifying_question",
				Agent:             profile.Name,
				ImmediateFeedback: fmt.Sprintf("What should I ask %s to work on?", profile.Name),
				RawTranscript:     input.Transcript,
			}
		}

		return UserRouterResult{
			Action:            "new_conversation",
			Agent:             profile.Name,
			Message:           message,
			ConversationTitle: placeholderConversationTitle(message),
			ImmediateFeedback: fmt.Sprintf("Starting a new %s conversation.", profile.Name),
			RawTranscript:     input.Transcript,
		}
	}

	return UserRouterResult{
		Action:            "ask_clarifying_question",
		ImmediateFeedback: "Say start a new conversation and the agent name, or mention an existing conversation handle.",
		RawTranscript:     input.Transcript,
	}
}

func extractNewConversationMessage(transcript string) string {
	trimmed := strings.TrimSpace(transcript)
	separators := []string{" to ", " for ", " about "}
	lowered := strings.ToLower(trimmed)
	for _, separator := range separators {
		if idx := strings.Index(lowered, separator); idx >= 0 {
			return strings.TrimSpace(trimmed[idx+len(separator):])
		}
	}
	return ""
}

func placeholderConversationTitle(message string) string {
	clean := strings.TrimSpace(message)
	if clean == "" {
		return "Untitled conversation"
	}

	reWhitespace := regexp.MustCompile(`\s+`)
	clean = reWhitespace.ReplaceAllString(clean, " ")
	if len(clean) <= 48 {
		return strings.ToUpper(clean[:1]) + clean[1:]
	}

	truncated := strings.TrimSpace(clean[:48])
	return strings.ToUpper(truncated[:1]) + truncated[1:]
}
