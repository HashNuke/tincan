package calls

import (
	"slices"
	"sync"
)

type EventSink interface {
	SendJSON(payload any) error
	Ready() bool
}

type Session struct {
	State           SessionState
	EventSink       EventSink
	ConversationIDs map[string]struct{}
}

type Manager struct {
	mu                   sync.Mutex
	sessions             map[string]*Session
	conversationSessions map[string]string
}

func NewManager() *Manager {
	return &Manager{
		sessions:             make(map[string]*Session),
		conversationSessions: make(map[string]string),
	}
}

func (m *Manager) RegisterSession(transportSessionID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[transportSessionID] = &Session{
		State:           SessionState{TransportSessionID: transportSessionID},
		ConversationIDs: make(map[string]struct{}),
	}
}

func (m *Manager) HasSession(transportSessionID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.sessions[transportSessionID]
	return ok
}

func (m *Manager) RemoveSession(transportSessionID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, transportSessionID)
	for conversationID, sessionID := range m.conversationSessions {
		if sessionID == transportSessionID {
			delete(m.conversationSessions, conversationID)
		}
	}
}

func (m *Manager) SetPushToTalk(transportSessionID string, active bool) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return false
	}
	session.State.PushToTalk = active
	return true
}

func (m *Manager) SetEventSink(transportSessionID string, sink EventSink) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return false
	}
	session.EventSink = sink
	return true
}

func (m *Manager) LinkConversation(transportSessionID string, conversationID string, conversationHandle string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return
	}
	session.ConversationIDs[conversationID] = struct{}{}
	session.State.CurrentConversationID = conversationID
	session.State.CurrentConversationHandle = conversationHandle
	m.conversationSessions[conversationID] = transportSessionID
}

func (m *Manager) SessionIDForConversation(conversationID string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sessionID, ok := m.conversationSessions[conversationID]
	return sessionID, ok
}

func (m *Manager) ConversationIDsForSession(transportSessionID string) []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return nil
	}

	conversationIDs := make([]string, 0, len(session.ConversationIDs))
	for conversationID := range session.ConversationIDs {
		conversationIDs = append(conversationIDs, conversationID)
	}
	slices.Sort(conversationIDs)
	return conversationIDs
}

func (m *Manager) ActiveConversationIDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()

	conversationIDs := make([]string, 0, len(m.sessions))
	seen := make(map[string]struct{}, len(m.sessions))
	for _, session := range m.sessions {
		if session.State.CurrentConversationID == "" {
			continue
		}
		if _, ok := seen[session.State.CurrentConversationID]; ok {
			continue
		}
		seen[session.State.CurrentConversationID] = struct{}{}
		conversationIDs = append(conversationIDs, session.State.CurrentConversationID)
	}
	slices.Sort(conversationIDs)
	return conversationIDs
}

func (m *Manager) CurrentConversationIDForSession(transportSessionID string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok || session.State.CurrentConversationID == "" {
		return "", false
	}
	return session.State.CurrentConversationID, true
}

func (m *Manager) CurrentConversationHandleForSession(transportSessionID string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok || session.State.CurrentConversationHandle == "" {
		return "", false
	}
	return session.State.CurrentConversationHandle, true
}

func (m *Manager) ClarificationHistoryForSession(transportSessionID string) []ClarificationMessage {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok || len(session.State.ClarificationHistory) == 0 {
		return nil
	}

	history := make([]ClarificationMessage, len(session.State.ClarificationHistory))
	copy(history, session.State.ClarificationHistory)
	return history
}

func (m *Manager) AppendClarificationExchange(transportSessionID string, userText string, agentQuestion string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return false
	}

	if userText != "" {
		session.State.ClarificationHistory = append(session.State.ClarificationHistory, ClarificationMessage{
			Role: "user",
			Text: userText,
		})
	}
	if agentQuestion != "" {
		session.State.ClarificationHistory = append(session.State.ClarificationHistory, ClarificationMessage{
			Role: "assistant",
			Text: agentQuestion,
		})
	}
	return true
}

func (m *Manager) ClearClarificationHistory(transportSessionID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return false
	}
	session.State.ClarificationHistory = nil
	return true
}

func (m *Manager) SendEvent(transportSessionID string, payload any) bool {
	m.mu.Lock()
	session, ok := m.sessions[transportSessionID]
	m.mu.Unlock()
	if !ok || session.EventSink == nil || !session.EventSink.Ready() {
		return false
	}
	return session.EventSink.SendJSON(payload) == nil
}
