package router

type UserRouterInput struct {
	Transcript                string   `json:"transcript"`
	CurrentConversationHandle string   `json:"current_conversation_handle,omitempty"`
	CurrentConversationNotes  string   `json:"current_conversation_notes,omitempty"`
	ConversationHandles       []string `json:"conversation_handles,omitempty"`
}

type UserRouterResult struct {
	Action                   string `json:"action"`
	Message                  string `json:"message,omitempty"`
	AgentProfile             string `json:"agent_profile,omitempty"`
	ConversationHandle       string `json:"conversation_handle,omitempty"`
	ConversationTitle        string `json:"conversation_title,omitempty"`
	UpdatedConversationNotes string `json:"updated_conversation_notes,omitempty"`
	ImmediateFeedback        string `json:"immediate_feedback,omitempty"`
	RawTranscript            string `json:"raw_transcript"`
}
