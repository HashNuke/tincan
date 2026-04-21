package main

import (
	"log"
	"net/http"
	"sync"
	"time"

	"golang.org/x/net/websocket"

	"tincan-server/conversations"
	"tincan-server/output"
	tincanrouter "tincan-server/router"
)

type liveSnapshot struct {
	Type                 string `json:"type"`
	HasActiveCall        bool   `json:"has_active_call"`
	ActiveConversationID string `json:"active_conversation_id,omitempty"`
	ServerTime           string `json:"server_time"`
}

type liveTextEvent struct {
	Type           string       `json:"type"`
	ConversationID string       `json:"conversation_id,omitempty"`
	Event          output.Event `json:"event"`
}

type liveConversationSummaryEvent struct {
	Type         string                            `json:"type"`
	Conversation conversations.ConversationSummary `json:"conversation"`
}

type liveConversationMessageEvent struct {
	Type           string                       `json:"type"`
	ConversationID string                       `json:"conversation_id"`
	Message        conversations.MessageSummary `json:"message"`
}

type liveActiveConversationEvent struct {
	Type                 string `json:"type"`
	HasActiveCall        bool   `json:"has_active_call"`
	ActiveConversationID string `json:"active_conversation_id,omitempty"`
}

type liveClient struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func (c *liveClient) send(payload any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return websocket.JSON.Send(c.conn, payload)
}

type liveHub struct {
	mu      sync.Mutex
	clients map[*liveClient]struct{}
	server  *server
}

func newLiveHub(server *server) *liveHub {
	return &liveHub{
		clients: make(map[*liveClient]struct{}),
		server:  server,
	}
}

func (h *liveHub) HandleEvent(event output.Event) error {
	payload := liveTextEvent{
		Type:  "text_event",
		Event: event,
	}
	if h != nil && h.server != nil {
		if conversationID, ok := h.server.conversationIDForSession(event.SessionID); ok {
			payload.ConversationID = conversationID
		}
	}
	h.broadcast(payload)
	return nil
}

func (h *liveHub) serveWebSocket(ws *websocket.Conn) {
	client := &liveClient{conn: ws}
	h.addClient(client)
	defer h.removeClient(client)

	if err := client.send(h.snapshot()); err != nil {
		log.Printf("live websocket snapshot failed: %v", err)
		return
	}

	var ignore any
	for {
		if err := websocket.JSON.Receive(ws, &ignore); err != nil {
			return
		}
	}
}

func (h *liveHub) snapshot() liveSnapshot {
	snapshot := liveSnapshot{
		Type:       "snapshot",
		ServerTime: time.Now().UTC().Format(time.RFC3339Nano),
	}
	if h == nil || h.server == nil {
		return snapshot
	}

	if activeConversationID, ok := h.server.activeConversationID(); ok {
		snapshot.HasActiveCall = true
		snapshot.ActiveConversationID = activeConversationID
	}
	return snapshot
}

func (h *liveHub) broadcastConversationSummary(summary conversations.ConversationSummary) {
	h.broadcast(liveConversationSummaryEvent{
		Type:         "conversation_summary_updated",
		Conversation: summary,
	})
}

func (h *liveHub) broadcastConversationMessage(conversationID string, message conversations.MessageSummary) {
	h.broadcast(liveConversationMessageEvent{
		Type:           "conversation_message_created",
		ConversationID: conversationID,
		Message:        message,
	})
}

func (h *liveHub) broadcastActiveConversationState() {
	payload := liveActiveConversationEvent{
		Type: "active_conversation_changed",
	}
	if h != nil && h.server != nil {
		if activeConversationID, ok := h.server.activeConversationID(); ok {
			payload.HasActiveCall = true
			payload.ActiveConversationID = activeConversationID
		}
	}
	h.broadcast(payload)
}

func (h *liveHub) handler() http.Handler {
	return websocket.Handler(h.serveWebSocket)
}

func (h *liveHub) addClient(client *liveClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[client] = struct{}{}
}

func (h *liveHub) removeClient(client *liveClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, client)
}

func (h *liveHub) broadcast(payload any) {
	if h == nil {
		return
	}

	h.mu.Lock()
	clients := make([]*liveClient, 0, len(h.clients))
	for client := range h.clients {
		clients = append(clients, client)
	}
	h.mu.Unlock()

	for _, client := range clients {
		if err := client.send(payload); err != nil {
			h.removeClient(client)
		}
	}
}

func (s *server) activeConversationID() (string, bool) {
	if s == nil || s.callManager == nil || s.conversations == nil {
		return "", false
	}

	backendConversationIDs := s.callManager.ActiveBackendConversationIDs()
	conversation, ok, err := s.conversations.GetMostRecentConversationByBackendConversationIDs(backendConversationIDs)
	if err != nil || !ok {
		return "", false
	}
	return conversation.ID, true
}

func (s *server) conversationIDForSession(sessionID string) (string, bool) {
	if s == nil || s.callManager == nil || s.conversations == nil {
		return "", false
	}

	backendConversationID, ok := s.callManager.CurrentBackendConversationIDForSession(sessionID)
	if !ok {
		return "", false
	}
	conversation, ok, err := s.conversations.GetConversationByBackendConversationID(backendConversationID)
	if err != nil || !ok {
		return "", false
	}
	return conversation.ID, true
}

func (s *server) broadcastConversationSummaryByID(conversationID string) {
	if s == nil || s.liveHub == nil || s.conversations == nil || conversationID == "" {
		return
	}
	summary, ok, err := s.conversations.GetConversationSummaryByID(conversationID)
	if err != nil || !ok {
		return
	}
	s.liveHub.broadcastConversationSummary(summary)
}

func (s *server) broadcastConversationMessageByID(conversationID string, messageID string) {
	if s == nil || s.liveHub == nil || s.conversations == nil || conversationID == "" || messageID == "" {
		return
	}
	message, ok, err := s.conversations.GetMessageByID(messageID)
	if err != nil || !ok || message.ConversationID != conversationID {
		return
	}
	s.liveHub.broadcastConversationMessage(conversationID, conversations.MessageSummary{
		ID:               message.ID,
		Kind:             "agent_update",
		SummaryText:      message.SummaryText,
		DetailText:       message.DetailText,
		NotificationText: message.NotificationText,
		Status:           message.Status,
		CreatedAt:        message.CreatedAt.UTC(),
		UpdatedAt:        message.UpdatedAt.UTC(),
		ConsumedAt:       message.ConsumedAt,
	})
}

func (s *server) broadcastLiveUpdatesForHandleResult(routeResult tincanrouter.RouteUserInputResult, responseBody map[string]any) {
	if s == nil || s.liveHub == nil {
		return
	}

	switch routeResult.Action {
	case "new_conversation", "switch_context", "message":
		s.liveHub.broadcastActiveConversationState()
	case "read_conversation_update":
		if update, ok := responseBody["update"].(conversations.Message); ok {
			s.broadcastConversationSummaryByID(update.ConversationID)
		}
	}

	if conversation, ok := responseBody["conversation"].(ConversationCreateResult); ok {
		s.broadcastConversationSummaryByID(conversation.ID)
	}
}
