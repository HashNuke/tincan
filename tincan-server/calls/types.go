package calls

type SessionState struct {
	TransportSessionID string
	PushToTalk         bool
}

type Event struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	URL      string `json:"url,omitempty"`
	AudioURL string `json:"audio_url,omitempty"`
}
