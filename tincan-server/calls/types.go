package calls

type SessionState struct {
	TransportSessionID string
	PushToTalk         bool
}

type PlayAudioEvent struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
	URL  string `json:"url,omitempty"`
}

type NotifyEvent struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	AudioURL string `json:"audio_url,omitempty"`
}

func NewPlayAudioEvent(text string, url string) PlayAudioEvent {
	return PlayAudioEvent{
		Type: "play_audio",
		Text: text,
		URL:  url,
	}
}

func NewNotifyEvent(text string, audioURL string) NotifyEvent {
	return NotifyEvent{
		Type:     "notify",
		Text:     text,
		AudioURL: audioURL,
	}
}
