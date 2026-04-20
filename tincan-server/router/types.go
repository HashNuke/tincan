package router

type ClarificationMessage struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

type RouteUserInputRequest struct {
	Transcript                string                 `json:"transcript"`
	CurrentConversationHandle string                 `json:"current_conversation_handle,omitempty"`
	CurrentConversationNotes  string                 `json:"current_conversation_notes,omitempty"`
	ConversationHandles       []string               `json:"conversation_handles,omitempty"`
	PendingUpdateHandles      []string               `json:"pending_update_handles,omitempty"`
	ClarificationHistory      []ClarificationMessage `json:"clarification_history,omitempty"`
}

type RouteUserInputResult struct {
	Action                   string `json:"action"`
	Message                  string `json:"message,omitempty"`
	AgentProfile             string `json:"agent_profile,omitempty"`
	ConversationHandle       string `json:"conversation_handle,omitempty"`
	ConversationTitle        string `json:"conversation_title,omitempty"`
	UpdatedConversationNotes string `json:"updated_conversation_notes,omitempty"`
	ImmediateFeedback        string `json:"immediate_feedback,omitempty"`
	RawTranscript            string `json:"raw_transcript"`
}
