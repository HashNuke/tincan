package router

type UserRouterInput struct {
	Transcript string
}

type UserRouterResult struct {
	Action             string `json:"action"`
	Message            string `json:"message,omitempty"`
	AgentProfile       string `json:"agent_profile,omitempty"`
	ConversationHandle string `json:"conversation_handle,omitempty"`
	ConversationTitle  string `json:"conversation_title,omitempty"`
	ImmediateFeedback  string `json:"immediate_feedback,omitempty"`
	RawTranscript      string `json:"raw_transcript"`
}
