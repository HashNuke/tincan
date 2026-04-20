package main

import "fmt"

type ConversationService struct {
	profiles      *AgentProfileStore
	backends      *AgentBackendStore
	conversations *ConversationStore
	agentAdapters map[string]AgentAdapter
}

type ConversationCreateInput struct {
	ProfileName string
	ConversationTitle string
	Message     string
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

func NewConversationService(profiles *AgentProfileStore, backends *AgentBackendStore, conversations *ConversationStore, agentAdapters map[string]AgentAdapter) *ConversationService {
	return &ConversationService{
		profiles:      profiles,
		backends:      backends,
		conversations: conversations,
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

	adapterResult, err := adapter.StartConversation(profile, backend, title, input.Message)
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("start backend conversation: %w", err)
	}

	conversation, err := s.conversations.CreateConversation(Conversation{
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
