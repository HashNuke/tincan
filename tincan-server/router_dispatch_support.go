package main

import (
	"strings"

	"tincan-server/calls"
	tincanrouter "tincan-server/router"
)

type conversationCreator struct {
	service *ConversationService
}

func (c conversationCreator) CreateConversation(profileName string, title string, message string) (tincanrouter.ConversationCreateResult, error) {
	result, err := c.service.CreateConversation(ConversationCreateInput{
		ProfileName:       profileName,
		ConversationTitle: title,
		Message:           message,
	})
	if err != nil {
		return tincanrouter.ConversationCreateResult{}, err
	}
	return tincanrouter.ConversationCreateResult{
		ID:                    result.ID,
		DisplayHandle:         result.DisplayHandle,
		ConversationNumber:    result.ConversationNumber,
		AgentProfileName:      result.AgentProfileName,
		AgentBackend:          result.AgentBackend,
		WorkingDirectory:      result.WorkingDirectory,
		BackendConversationID: result.BackendConversationID,
		Status:                result.Status,
	}, nil
}

type sessionAudioNotifier struct {
	server *server
}

func (n sessionAudioNotifier) Speak(sessionID string, text string) error {
	if n.server == nil || strings.TrimSpace(text) == "" {
		return nil
	}
	audioURL, err := n.server.generateFeedbackAudio(text)
	if err != nil {
		return err
	}
	n.server.sendSessionEvent(sessionID, calls.NewPlayAudioEvent(text, audioURL))
	return nil
}
