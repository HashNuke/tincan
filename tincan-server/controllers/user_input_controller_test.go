package controllers

import (
	"testing"

	"tincan-server/calls"
	"tincan-server/conversations"
	"tincan-server/output"
	tincanrouter "tincan-server/router"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

type fakeRouter struct {
	result tincanrouter.RouteUserInputResult
	err    error
	input  tincanrouter.RouteUserInputRequest
}

func (f *fakeRouter) RouteUserInput(input tincanrouter.RouteUserInputRequest) (tincanrouter.RouteUserInputResult, error) {
	f.input = input
	return f.result, f.err
}

type fakeCallState struct {
	currentHandle    string
	currentBackendID string
	history          []calls.ClarificationMessage

	linkCalls                 []linkedConversation
	appendClarificationCalls  []clarificationExchange
	clearClarificationInvoked int
}

type linkedConversation struct {
	sessionID             string
	backendConversationID string
	handle                string
}

type clarificationExchange struct {
	sessionID string
	userText  string
	question  string
}

func (f *fakeCallState) LinkConversation(transportSessionID string, backendConversationID string, conversationHandle string) {
	f.linkCalls = append(f.linkCalls, linkedConversation{
		sessionID:             transportSessionID,
		backendConversationID: backendConversationID,
		handle:                conversationHandle,
	})
	f.currentHandle = conversationHandle
	f.currentBackendID = backendConversationID
}

func (f *fakeCallState) AppendClarificationExchange(transportSessionID string, userText string, agentQuestion string) bool {
	f.appendClarificationCalls = append(f.appendClarificationCalls, clarificationExchange{
		sessionID: transportSessionID,
		userText:  userText,
		question:  agentQuestion,
	})
	return true
}

func (f *fakeCallState) ClearClarificationHistory(transportSessionID string) bool {
	f.clearClarificationInvoked++
	f.history = nil
	return true
}

func (f *fakeCallState) CurrentConversationHandleForSession(transportSessionID string) (string, bool) {
	if f.currentHandle == "" {
		return "", false
	}
	return f.currentHandle, true
}

func (f *fakeCallState) CurrentBackendConversationIDForSession(transportSessionID string) (string, bool) {
	if f.currentBackendID == "" {
		return "", false
	}
	return f.currentBackendID, true
}

func (f *fakeCallState) ClarificationHistoryForSession(transportSessionID string) []calls.ClarificationMessage {
	out := make([]calls.ClarificationMessage, len(f.history))
	copy(out, f.history)
	return out
}

type fakeConversationCreator struct {
	result ConversationCreateResult
	err    error
	calls  []createConversationCall
}

type createConversationCall struct {
	profile string
	title   string
	message string
}

func (f *fakeConversationCreator) CreateConversation(profileName string, title string, message string) (ConversationCreateResult, error) {
	f.calls = append(f.calls, createConversationCall{profile: profileName, title: title, message: message})
	return f.result, f.err
}

type fakeConversationMessenger struct {
	err   error
	calls []continueConversationCall
}

type continueConversationCall struct {
	conversation conversations.Conversation
	message      string
}

func (f *fakeConversationMessenger) ContinueConversation(conversation conversations.Conversation, message string) error {
	f.calls = append(f.calls, continueConversationCall{conversation: conversation, message: message})
	return f.err
}

func TestUserInputControllerAskClarifyingQuestionAppendsHistoryAndEmitsOutput(t *testing.T) {
	store := newTestConversationStore(t)
	router := &fakeRouter{
		result: tincanrouter.RouteUserInputResult{
			Action:            "ask_clarifying_question",
			ImmediateFeedback: "Which Emma conversation do you mean?",
		},
	}
	callState := &fakeCallState{}
	controller := &UserInputController{
		Router:        router,
		Calls:         callState,
		Conversations: store,
	}

	result, err := controller.HandleTranscript("session-1", "Emma, what do you have?")
	if err != nil {
		t.Fatalf("HandleTranscript returned error: %v", err)
	}

	if len(callState.appendClarificationCalls) != 1 {
		t.Fatalf("expected 1 clarification append call, got %d", len(callState.appendClarificationCalls))
	}
	gotAppend := callState.appendClarificationCalls[0]
	if gotAppend.userText != "Emma, what do you have?" || gotAppend.question != "Which Emma conversation do you mean?" {
		t.Fatalf("unexpected clarification exchange: %+v", gotAppend)
	}

	if len(result.OutputEvents) != 2 {
		t.Fatalf("expected 2 output events, got %d", len(result.OutputEvents))
	}
	if result.OutputEvents[0].Kind != output.KindImmediateFeedback {
		t.Fatalf("expected first event to be immediate feedback, got %q", result.OutputEvents[0].Kind)
	}
	if result.OutputEvents[1].Kind != output.KindClarificationQuestion {
		t.Fatalf("expected second event to be clarification question, got %q", result.OutputEvents[1].Kind)
	}
}

func TestUserInputControllerReadConversationUpdateConsumesPendingUpdate(t *testing.T) {
	store := newTestConversationStore(t)
	conversation := createTestConversation(t, store, conversations.Conversation{
		ID:                    "conv-1",
		DisplayHandle:         "emma#10",
		AgentProfileName:      "emma",
		ConversationNumber:    10,
		AgentBackend:          "opencode-1",
		WorkingDirectory:      "/tmp/project",
		BackendConversationID: "backend-1",
		Status:                "running",
	})
	update, changed, err := store.CreateMessage(conversations.Message{
		ConversationID:     conversation.ID,
		ConversationHandle: conversation.DisplayHandle,
		SummaryText:        "Build is green now.",
		DetailText:         "Build is green now, the flaky auth test is fixed, and I committed the change.",
		NotificationText:   "emma#10 has an update.",
		RawUpdateJSON:      `{"ok":true}`,
		Status:             "pending",
	})
	if err != nil {
		t.Fatalf("CreateMessage returned error: %v", err)
	}
	if !changed {
		t.Fatalf("expected initial update upsert to report changed")
	}

	router := &fakeRouter{
		result: tincanrouter.RouteUserInputResult{
			Action:             "read_conversation_update",
			ConversationHandle: "emma 10",
		},
	}
	callState := &fakeCallState{}
	controller := &UserInputController{
		Router:        router,
		Calls:         callState,
		Conversations: store,
	}

	result, err := controller.HandleTranscript("session-1", "Emma 10 what do you have for me")
	if err != nil {
		t.Fatalf("HandleTranscript returned error: %v", err)
	}

	if got := result.ResponseBody["resolved_conversation_handle"]; got != "emma#10" {
		t.Fatalf("expected resolved handle emma#10, got %#v", got)
	}
	storedUpdate, ok := result.ResponseBody["update"].(conversations.Message)
	if !ok {
		t.Fatalf("expected response body update, got %#v", result.ResponseBody["update"])
	}
	if storedUpdate.DetailText != "Build is green now, the flaky auth test is fixed, and I committed the change." {
		t.Fatalf("unexpected update detail text: %q", storedUpdate.DetailText)
	}
	if len(result.OutputEvents) != 1 || result.OutputEvents[0].Kind != output.KindUpdateSummary {
		t.Fatalf("expected one update summary event, got %+v", result.OutputEvents)
	}
	if result.OutputEvents[0].Text != "Build is green now." {
		t.Fatalf("unexpected update summary text: %q", result.OutputEvents[0].Text)
	}

	latest, ok, err := store.GetLatestPendingMessageByConversationID(conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestPendingMessageByConversationID returned error: %v", err)
	}
	if ok {
		t.Fatalf("expected pending update to be consumed, still found %+v", latest)
	}

	pendingUpdates, err := store.ListPendingMessages(10)
	if err != nil {
		t.Fatalf("ListPendingMessages returned error: %v", err)
	}
	for _, pending := range pendingUpdates {
		if pending.ID == update.ID {
			t.Fatalf("expected update %q to be absent from pending updates after consume", update.ID)
		}
	}
}

func TestUserInputControllerMessageUsesCurrentConversationContext(t *testing.T) {
	store := newTestConversationStore(t)
	conversation := createTestConversation(t, store, conversations.Conversation{
		ID:                    "conv-2",
		DisplayHandle:         "emma#2",
		AgentProfileName:      "emma",
		ConversationNumber:    2,
		AgentBackend:          "opencode-1",
		WorkingDirectory:      "/tmp/project",
		BackendConversationID: "backend-2",
		Status:                "running",
	})

	router := &fakeRouter{
		result: tincanrouter.RouteUserInputResult{
			Action:            "message",
			Message:           "keep going on the auth fix",
			ImmediateFeedback: "Sending that to emma#2.",
		},
	}
	callState := &fakeCallState{
		currentHandle:    conversation.DisplayHandle,
		currentBackendID: conversation.BackendConversationID,
	}
	messenger := &fakeConversationMessenger{}
	controller := &UserInputController{
		Router:           router,
		Calls:            callState,
		Conversations:    store,
		ConversationSend: messenger,
	}

	result, err := controller.HandleTranscript("session-1", "tell emma to keep going")
	if err != nil {
		t.Fatalf("HandleTranscript returned error: %v", err)
	}

	if len(messenger.calls) != 1 {
		t.Fatalf("expected one continue conversation call, got %d", len(messenger.calls))
	}
	if messenger.calls[0].conversation.ID != conversation.ID {
		t.Fatalf("expected conversation %q, got %q", conversation.ID, messenger.calls[0].conversation.ID)
	}
	if messenger.calls[0].message != "keep going on the auth fix" {
		t.Fatalf("unexpected message: %q", messenger.calls[0].message)
	}
	if len(callState.linkCalls) != 1 {
		t.Fatalf("expected current conversation to be re-linked once, got %d", len(callState.linkCalls))
	}
	if callState.clearClarificationInvoked != 1 {
		t.Fatalf("expected clarification history clear once, got %d", callState.clearClarificationInvoked)
	}
	if got := result.ResponseBody["resolved_conversation_handle"]; got != "emma#2" {
		t.Fatalf("expected resolved handle emma#2, got %#v", got)
	}
	if len(result.OutputEvents) != 1 || result.OutputEvents[0].Kind != output.KindImmediateFeedback {
		t.Fatalf("expected one immediate feedback event, got %+v", result.OutputEvents)
	}
}

func newTestConversationStore(t *testing.T) *conversations.Store {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("failed to open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&conversations.Conversation{}, &conversations.Message{}, &conversations.ConversationNote{}); err != nil {
		t.Fatalf("failed to migrate test db: %v", err)
	}
	return conversations.NewStore(db)
}

func createTestConversation(t *testing.T, store *conversations.Store, conversation conversations.Conversation) conversations.Conversation {
	t.Helper()
	created, err := store.CreateConversation(conversation)
	if err != nil {
		t.Fatalf("CreateConversation returned error: %v", err)
	}
	return created
}
