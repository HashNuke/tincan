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
	State                  SessionState
	EventSink              EventSink
	BackendConversationIDs map[string]struct{}
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
		State:                  SessionState{TransportSessionID: transportSessionID},
		BackendConversationIDs: make(map[string]struct{}),
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
	for backendID, sessionID := range m.conversationSessions {
		if sessionID == transportSessionID {
			delete(m.conversationSessions, backendID)
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

func (m *Manager) LinkConversation(transportSessionID string, backendConversationID string, conversationHandle string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return
	}
	session.BackendConversationIDs[backendConversationID] = struct{}{}
	session.State.CurrentBackendConversationID = backendConversationID
	session.State.CurrentConversationHandle = conversationHandle
	m.conversationSessions[backendConversationID] = transportSessionID
}

func (m *Manager) SessionIDForConversation(backendConversationID string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sessionID, ok := m.conversationSessions[backendConversationID]
	return sessionID, ok
}

func (m *Manager) BackendConversationIDsForSession(transportSessionID string) []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok {
		return nil
	}

	backendConversationIDs := make([]string, 0, len(session.BackendConversationIDs))
	for backendConversationID := range session.BackendConversationIDs {
		backendConversationIDs = append(backendConversationIDs, backendConversationID)
	}
	slices.Sort(backendConversationIDs)
	return backendConversationIDs
}

func (m *Manager) CurrentBackendConversationIDForSession(transportSessionID string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	session, ok := m.sessions[transportSessionID]
	if !ok || session.State.CurrentBackendConversationID == "" {
		return "", false
	}
	return session.State.CurrentBackendConversationID, true
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

func (m *Manager) SendEvent(transportSessionID string, payload any) bool {
	m.mu.Lock()
	session, ok := m.sessions[transportSessionID]
	m.mu.Unlock()
	if !ok || session.EventSink == nil || !session.EventSink.Ready() {
		return false
	}
	return session.EventSink.SendJSON(payload) == nil
}
