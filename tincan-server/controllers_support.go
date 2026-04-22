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
	audioData, err := r.server.inference.synthesize(text)
	if err != nil {
		return err
	}

	audioURL := ""
	if err := r.server.queueSessionAudio(sessionID, audioData); err != nil {
		audioURL, err = r.server.writeGeneratedAudio(audioData)
		if err != nil {
			return err
		}
	}

	r.server.sendSessionEvent(sessionID, calls.NewPlayAudioEvent(text, audioURL))
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

	audioData, err := r.server.inference.synthesize(spokenText)
	if err != nil {
		return err
	}

	if spokenSummary == "" {
		spokenSummary = notificationText
	}

	audioURL := ""
	summaryAudioURL := ""
	if err := r.server.queueSessionAudio(sessionID, audioData); err != nil {
		summaryAudioURL, err = r.server.writeGeneratedAudio(audioData)
		if err != nil {
			return err
		}
		audioURL = summaryAudioURL
	}

	r.server.sendSessionEvent(sessionID, calls.NewNotifyEvent(notificationText, audioURL, spokenSummary, summaryAudioURL))
	return nil
}

func (s *server) publishOutput(events ...output.Event) error {
	if s.outputPublisher == nil {
		return nil
	}
	return s.outputPublisher.Publish(events...)
}
