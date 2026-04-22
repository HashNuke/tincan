package main

import (
	"fmt"
	"log"
	"strings"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
)

type ConversationDispatcher interface {
	DispatchConversation(conversationID string, title string) (ManagedDispatchResult, error)
}

type ConversationService struct {
	profiles      *tincanconfig.AgentProfileStore
	backends      *tincanconfig.AgentBackendStore
	conversations *conversations.Store
	agentAdapters map[string]agent_adapters.Adapter
	dispatcher    ConversationDispatcher
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

type ConversationContinueResult struct {
	Conversation conversations.Conversation
	Queued       bool
}

func NewConversationService(
	profiles *tincanconfig.AgentProfileStore,
	backends *tincanconfig.AgentBackendStore,
	conversationsStore *conversations.Store,
	agentAdapters map[string]agent_adapters.Adapter,
	dispatcher ConversationDispatcher,
) *ConversationService {
	return &ConversationService{
		profiles:      profiles,
		backends:      backends,
		conversations: conversationsStore,
		agentAdapters: agentAdapters,
		dispatcher:    dispatcher,
	}
}

func (s *ConversationService) CreateConversation(input ConversationCreateInput) (ConversationCreateResult, error) {
	if strings.TrimSpace(input.Message) == "" {
		return ConversationCreateResult{}, fmt.Errorf("create conversation requires non-empty message")
	}

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
	if err := adapter.ValidateBackend(profile.AgentBackend, backend); err != nil {
		return ConversationCreateResult{}, err
	}

	conversationNumber, err := s.conversations.NextConversationNumber(profile.Name)
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("allocate conversation number: %w", err)
	}

	title := input.ConversationTitle
	if title == "" {
		title = "Untitled conversation"
	}

	conversation, err := s.conversations.CreateConversation(conversations.Conversation{
		DisplayHandle:         fmt.Sprintf("%s#%d", profile.Name, conversationNumber),
		AgentProfileName:      profile.Name,
		ConversationNumber:    conversationNumber,
		AgentBackend:          profile.AgentBackend,
		WorkingDirectory:      profile.WorkingDirectory,
		BackendConversationID: "",
		Status:                "starting",
	})
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("persist conversation: %w", err)
	}

	if _, err := s.conversations.EnqueueConversationInput(conversation.ID, input.Message); err != nil {
		return ConversationCreateResult{}, fmt.Errorf("enqueue initial conversation input: %w", err)
	}

	log.Printf(
		"created managed conversation: handle=%q status=%q title=%q",
		conversation.DisplayHandle,
		conversation.Status,
		title,
	)

	if s.dispatcher == nil {
		return ConversationCreateResult{}, fmt.Errorf("conversation dispatcher is not configured")
	}

	dispatchResult, err := s.dispatcher.DispatchConversation(conversation.ID, title)
	if err != nil {
		return ConversationCreateResult{}, fmt.Errorf("dispatch managed conversation: %w", err)
	}
	if !dispatchResult.Started {
		return ConversationCreateResult{}, fmt.Errorf("managed conversation did not start for %q", conversation.DisplayHandle)
	}

	refreshedConversation, ok, err := s.conversations.GetConversationByID(conversation.ID)
	if err != nil {
		return ConversationCreateResult{}, err
	}
	if !ok {
		return ConversationCreateResult{}, fmt.Errorf("conversation %q disappeared after creation", conversation.ID)
	}

	return ConversationCreateResult{
		ID:                    refreshedConversation.ID,
		DisplayHandle:         refreshedConversation.DisplayHandle,
		ConversationNumber:    refreshedConversation.ConversationNumber,
		AgentProfileName:      refreshedConversation.AgentProfileName,
		AgentBackend:          refreshedConversation.AgentBackend,
		WorkingDirectory:      refreshedConversation.WorkingDirectory,
		BackendConversationID: refreshedConversation.BackendConversationID,
		Status:                refreshedConversation.Status,
	}, nil
}

func (s *ConversationService) ContinueConversation(input ConversationMessageInput) (ConversationContinueResult, error) {
	if strings.TrimSpace(input.Message) == "" {
		return ConversationContinueResult{}, fmt.Errorf("continue conversation requires non-empty message")
	}

	backend, ok := s.backends.Get(input.Conversation.AgentBackend)
	if !ok {
		return ConversationContinueResult{}, fmt.Errorf("unknown agent backend %q", input.Conversation.AgentBackend)
	}

	adapter, ok := s.agentAdapters[backend.Type]
	if !ok {
		return ConversationContinueResult{}, fmt.Errorf("no agent adapter for backend type %q", backend.Type)
	}
	if err := adapter.ValidateBackend(input.Conversation.AgentBackend, backend); err != nil {
		return ConversationContinueResult{}, err
	}

	if _, err := s.conversations.EnqueueConversationInput(input.Conversation.ID, input.Message); err != nil {
		return ConversationContinueResult{}, fmt.Errorf("enqueue conversation input: %w", err)
	}

	if s.dispatcher == nil {
		return ConversationContinueResult{}, fmt.Errorf("conversation dispatcher is not configured")
	}

	dispatchResult, err := s.dispatcher.DispatchConversation(input.Conversation.ID, "")
	if err != nil {
		return ConversationContinueResult{}, fmt.Errorf("dispatch conversation input: %w", err)
	}

	refreshedConversation, ok, err := s.conversations.GetConversationByID(input.Conversation.ID)
	if err != nil {
		return ConversationContinueResult{}, err
	}
	if !ok {
		return ConversationContinueResult{}, fmt.Errorf("conversation %q not found", input.Conversation.ID)
	}

	log.Printf(
		"queued managed conversation input: handle=%q queued=%t status=%q",
		refreshedConversation.DisplayHandle,
		!dispatchResult.Started,
		refreshedConversation.Status,
	)

	return ConversationContinueResult{
		Conversation: refreshedConversation,
		Queued:       !dispatchResult.Started,
	}, nil
}
