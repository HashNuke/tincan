package main

import (
	"strings"

	"tincan-server/calls"
	"tincan-server/controllers"
	"tincan-server/conversations"
	"tincan-server/output"
)

type conversationCreator struct {
	service *ConversationService
}

func (c conversationCreator) CreateConversation(profileName string, title string, message string) (controllers.ConversationCreateResult, error) {
	result, err := c.service.CreateConversation(ConversationCreateInput{
		ProfileName:       profileName,
		ConversationTitle: title,
		Message:           message,
	})
	if err != nil {
		return controllers.ConversationCreateResult{}, err
	}
	return controllers.ConversationCreateResult{
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

type conversationMessenger struct {
	service *ConversationService
}

func (m conversationMessenger) ContinueConversation(conversation conversations.Conversation, message string) error {
	return m.service.ContinueConversation(ConversationMessageInput{
		Conversation: conversation,
		Message:      message,
	})
}

type callAudioRenderer struct {
	server *server
}

func (r callAudioRenderer) PlaySpeech(sessionID string, text string) error {
	if r.server == nil || strings.TrimSpace(text) == "" {
		return nil
	}
	audioURL, err := r.server.generateFeedbackAudio(text)
	if err != nil {
		return err
	}
	r.server.sendSessionEvent(sessionID, calls.NewPlayAudioEvent(text, audioURL))
	return nil
}

func (r callAudioRenderer) NotifySpeech(sessionID string, text string) error {
	if r.server == nil || strings.TrimSpace(text) == "" {
		return nil
	}
	audioURL, err := r.server.generateFeedbackAudio(text)
	if err != nil {
		return err
	}
	r.server.sendSessionEvent(sessionID, calls.NewNotifyEvent(text, audioURL))
	return nil
}

func (s *server) publishOutput(events ...output.Event) error {
	if s.outputPublisher == nil {
		return nil
	}
	return s.outputPublisher.Publish(events...)
}
