package prompts

import (
	"bytes"
	"embed"
	"strings"
	"text/template"
)

//go:embed *.tmpl
var templateFS embed.FS

type RouterUserPromptData struct {
	RouterProfileName            string
	DefinedAgentProfiles         []string
	KnownConversationHandles     []string
	CurrentConversationHandle    string
	CurrentConversationNotes     string
	PendingUpdateHandles         []string
	UnresolvedClarificationLines []string
	UserTranscript               string
}

type ConversationUpdatePromptData struct {
	ConversationHandle string
	DetailText         string
}

var promptTemplates = template.Must(template.New("prompts").ParseFS(templateFS, "*.tmpl"))

func RenderRouterUserPrompt(data RouterUserPromptData) (string, error) {
	return renderTemplate("router_user", data)
}

func RenderConversationUpdatePrompt(data ConversationUpdatePromptData) (string, error) {
	return renderTemplate("conversation_update", data)
}

func renderTemplate(name string, data any) (string, error) {
	var buffer bytes.Buffer
	if err := promptTemplates.ExecuteTemplate(&buffer, name, data); err != nil {
		return "", err
	}
	return strings.TrimSpace(buffer.String()), nil
}
