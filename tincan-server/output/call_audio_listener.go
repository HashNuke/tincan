package output

import "strings"

type CallAudioRenderer interface {
	PlaySpeech(sessionID string, text string) error
	NotifySpeech(sessionID string, text string, summaryText string) error
}

type CallAudioListener struct {
	Renderer CallAudioRenderer
}

func (l CallAudioListener) HandleEvent(event Event) error {
	if l.Renderer == nil || strings.TrimSpace(event.Text) == "" {
		return nil
	}

	switch event.Kind {
	case KindNotification:
		return l.Renderer.NotifySpeech(event.SessionID, event.Text, event.SummaryText)
	case KindImmediateFeedback, KindClarificationQuestion, KindUpdateSummary, KindContextSwitch:
		return l.Renderer.PlaySpeech(event.SessionID, event.Text)
	default:
		return nil
	}
}
