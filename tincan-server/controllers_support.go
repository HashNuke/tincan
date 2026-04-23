package main

import (
	"log"
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

func (m conversationMessenger) ContinueConversation(conversation conversations.Conversation, message string) (controllers.ConversationSendResult, error) {
	result, err := m.service.ContinueConversation(ConversationMessageInput{
		Conversation: conversation,
		Message:      message,
	})
	if err != nil {
		return controllers.ConversationSendResult{}, err
	}
	return controllers.ConversationSendResult{
		ConversationID: result.Conversation.ID,
		DisplayHandle:  result.Conversation.DisplayHandle,
		Queued:         result.Queued,
	}, nil
}

type callAudioRenderer struct {
	server *server
}

func (r callAudioRenderer) PlaySpeech(sessionID string, text string) error {
	if r.server == nil || strings.TrimSpace(text) == "" {
		return nil
	}
	audioData, err := r.server.tts.synthesize(text)
	if err != nil {
		return err
	}

	if err := r.server.queueSessionAudio(sessionID, audioData); err != nil {
		log.Printf("peer %s failed to queue live audio for play event: %v", sessionID, err)
	}

	r.server.sendSessionEvent(sessionID, calls.NewPlayAudioEvent(text))
	return nil
}

func (r callAudioRenderer) NotifySpeech(sessionID string, text string, summaryText string) error {
	if r.server == nil {
		return nil
	}
	notificationText := strings.TrimSpace(text)
	spokenSummary := strings.TrimSpace(summaryText)
	if notificationText == "" {
		notificationText = spokenSummary
	}
	if notificationText == "" {
		return nil
	}

	spokenText := spokenSummary
	if spokenText == "" {
		spokenText = notificationText
	}

	audioData, err := r.server.tts.synthesize(spokenText)
	if err != nil {
		return err
	}

	if spokenSummary == "" {
		spokenSummary = notificationText
	}

	if err := r.server.queueSessionAudio(sessionID, audioData); err != nil {
		log.Printf("peer %s failed to queue live audio for notify event: %v", sessionID, err)
	}

	r.server.sendSessionEvent(sessionID, calls.NewNotifyEvent(notificationText, spokenSummary))
	return nil
}

func (s *server) publishOutput(events ...output.Event) error {
	if s.outputPublisher == nil {
		return nil
	}
	return s.outputPublisher.Publish(events...)
}
