package main

import (
	"fmt"
	"log"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
)

type ConversationService struct {
	profiles      *tincanconfig.AgentProfileStore
	backends      *tincanconfig.AgentBackendStore
	conversations *conversations.Store
	agentAdapters map[string]agent_adapters.Adapter
}

type ConversationCreateInput struct {
	ProfileName       string
	ConversationTitle string
	Message           string
}

type ConversationMessageInput struct {
	Conversation conversations.Conversation
	Message      string
}

type ConversationCreateResult struct {
	ID                    string `json:"id"`
	DisplayHandle         string `json:"display_handle"`
	ConversationNumber    int    `json:"conversation_number"`
	AgentProfileName      string `json:"agent_profile_name"`
	AgentBackend          string `json:"agent_backend"`
	WorkingDirectory      string `json:"working_directory"`
	BackendConversationID string `json:"backend_conversation_id"`
	Status                string `json:"status"`
}

func NewConversationService(profiles *tincanconfig.AgentProfileStore, backends *tincanconfig.AgentBackendStore, conversationsStore *conversations.Store, agentAdapters map[string]agent_adapters.Adapter) *ConversationService {
	return &ConversationService{
		profiles:      profiles,
		backends:      backends,
		conversations: conversationsStore,
		agentAdapters: agentAdapters,
	}
}

func (s *ConversationService) CreateConversation(input ConversationCreateInput) (ConversationCreateResult, error) {
	profile, ok := s.profiles.Get(input.ProfileName)
	if !ok {
		return ConversationCreateResult{}, fmt.Errorf("unknown agent profile %q", input.ProfileName)
	}

	backend, ok := s.backends.Get(profile.AgentBackend)
	if !ok {
		return ConversationCreateResult{}, fmt.Errorf("unknown agent backend %q", profile.AgentBackend)
	}

	adapter, ok := s.agentAdapters[backend.Type]
	if !ok {
		return ConversationCreateResult{}, fmt.Errorf("no agent adapter for backend type %q", backend.Type)
	}

	conversationNumber, err := s.conversations.NextConversationNumber(profile.Name)
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("allocate conversation number: %w", err)
	}

	title := input.ConversationTitle
	if title == "" {
		title = "Untitled conversation"
	}

	log.Printf(
		"starting backend conversation: profile=%q backend=%q backend_type=%q working_directory=%q title=%q",
		profile.Name,
		profile.AgentBackend,
		backend.Type,
		profile.WorkingDirectory,
		title,
	)

	adapterResult, err := adapter.StartConversation(profile, backend, title, input.Message)
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("start backend conversation: %w", err)
	}

	conversation, err := s.conversations.CreateConversation(conversations.Conversation{
		DisplayHandle:         fmt.Sprintf("%s#%d", profile.Name, conversationNumber),
		AgentProfileName:      profile.Name,
		ConversationNumber:    conversationNumber,
		AgentBackend:          profile.AgentBackend,
		WorkingDirectory:      profile.WorkingDirectory,
		BackendConversationID: adapterResult.BackendConversationID,
		Status:                adapterResult.Status,
	})
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("persist conversation: %w", err)
	}

	log.Printf(
		"created conversation: handle=%q backend_conversation_id=%q status=%q",
		conversation.DisplayHandle,
		conversation.BackendConversationID,
		conversation.Status,
	)

	return ConversationCreateResult{
		ID:                    conversation.ID,
		DisplayHandle:         conversation.DisplayHandle,
		ConversationNumber:    conversation.ConversationNumber,
		AgentProfileName:      conversation.AgentProfileName,
		AgentBackend:          conversation.AgentBackend,
		WorkingDirectory:      conversation.WorkingDirectory,
		BackendConversationID: conversation.BackendConversationID,
		Status:                conversation.Status,
	}, nil
}

func (s *ConversationService) ContinueConversation(input ConversationMessageInput) error {
	if input.Message == "" {
		return fmt.Errorf("continue conversation requires non-empty message")
	}

	backend, ok := s.backends.Get(input.Conversation.AgentBackend)
	if !ok {
		return fmt.Errorf("unknown agent backend %q", input.Conversation.AgentBackend)
	}

	adapter, ok := s.agentAdapters[backend.Type]
	if !ok {
		return fmt.Errorf("no agent adapter for backend type %q", backend.Type)
	}

	log.Printf(
		"continuing backend conversation: handle=%q backend_conversation_id=%q backend=%q backend_type=%q",
		input.Conversation.DisplayHandle,
		input.Conversation.BackendConversationID,
		input.Conversation.AgentBackend,
		backend.Type,
	)

	if err := adapter.ContinueConversation(input.Conversation, backend, input.Message); err != nil {
		return fmt.Errorf("continue backend conversation: %w", err)
	}

	log.Printf(
		"scheduled backend continuation: handle=%q backend_conversation_id=%q",
		input.Conversation.DisplayHandle,
		input.Conversation.BackendConversationID,
	)

	return nil
}
