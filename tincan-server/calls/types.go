package calls

type ClarificationMessage struct {
	Role string
	Text string
}

type SessionState struct {
	TransportSessionID        string
	PushToTalk                bool
	CurrentConversationID     string
	CurrentConversationHandle string
	ClarificationHistory      []ClarificationMessage
}

type PlayAudioEvent struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

type NotifyEvent struct {
	Type        string `json:"type"`
	Text        string `json:"text,omitempty"`
	SummaryText string `json:"summary_text,omitempty"`
}

func NewPlayAudioEvent(text string) PlayAudioEvent {
	return PlayAudioEvent{
		Type: "play_audio",
		Text: text,
	}
}

func NewNotifyEvent(text string, summaryText string) NotifyEvent {
	return NotifyEvent{
		Type:        "notify",
		Text:        text,
		SummaryText: summaryText,
	}
}
