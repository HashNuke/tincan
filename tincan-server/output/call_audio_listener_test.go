package output

import "testing"

type fakeCallAudioRenderer struct {
	playCalls   []renderCall
	notifyCalls []renderCall
}

type renderCall struct {
	sessionID  string
	text       string
	detailText string
}

func (f *fakeCallAudioRenderer) PlaySpeech(sessionID string, text string) error {
	f.playCalls = append(f.playCalls, renderCall{sessionID: sessionID, text: text})
	return nil
}

func (f *fakeCallAudioRenderer) NotifySpeech(sessionID string, text string, detailText string) error {
	f.notifyCalls = append(f.notifyCalls, renderCall{sessionID: sessionID, text: text, detailText: detailText})
	return nil
}

func TestCallAudioListenerRoutesKindsToCorrectRendererMethod(t *testing.T) {
	renderer := &fakeCallAudioRenderer{}
	listener := CallAudioListener{Renderer: renderer}

	events := []Event{
		{SessionID: "s1", Kind: KindImmediateFeedback, Text: "Working on it."},
		{SessionID: "s1", Kind: KindClarificationQuestion, Text: "Which one?"},
		{SessionID: "s1", Kind: KindUpdateSummary, Text: "The build passed."},
		{SessionID: "s1", Kind: KindContextSwitch, Text: "Switched to emma#2."},
		{SessionID: "s1", Kind: KindNotification, Text: "emma#2 has an update.", DetailText: "The build passed."},
	}

	for _, event := range events {
		if err := listener.HandleEvent(event); err != nil {
			t.Fatalf("HandleEvent returned error: %v", err)
		}
	}

	if len(renderer.playCalls) != 4 {
		t.Fatalf("expected 4 play calls, got %d", len(renderer.playCalls))
	}
	if len(renderer.notifyCalls) != 1 {
		t.Fatalf("expected 1 notify call, got %d", len(renderer.notifyCalls))
	}
	if renderer.notifyCalls[0].text != "emma#2 has an update." {
		t.Fatalf("unexpected notify text: %q", renderer.notifyCalls[0].text)
	}
	if renderer.notifyCalls[0].detailText != "The build passed." {
		t.Fatalf("unexpected notify detail text: %q", renderer.notifyCalls[0].detailText)
	}
}

func TestCallAudioListenerSkipsEmptyText(t *testing.T) {
	renderer := &fakeCallAudioRenderer{}
	listener := CallAudioListener{Renderer: renderer}

	if err := listener.HandleEvent(Event{SessionID: "s1", Kind: KindNotification, Text: "   "}); err != nil {
		t.Fatalf("HandleEvent returned error: %v", err)
	}

	if len(renderer.playCalls) != 0 || len(renderer.notifyCalls) != 0 {
		t.Fatalf("expected no renderer calls, got play=%d notify=%d", len(renderer.playCalls), len(renderer.notifyCalls))
	}
}
