package main

import (
	"testing"

	"tincan-server/calls"
)

type fakeCallRendererTTS struct {
	audioData []byte
	err       error
}

func (f fakeCallRendererTTS) synthesize(text string) ([]byte, error) {
	if f.err != nil {
		return nil, f.err
	}
	return append([]byte(nil), f.audioData...), nil
}

type recordingEventSink struct {
	payloads []any
}

func (s *recordingEventSink) SendJSON(payload any) error {
	s.payloads = append(s.payloads, payload)
	return nil
}

func (s *recordingEventSink) Ready() bool {
	return true
}

func TestCallAudioRendererPlaySpeechStillSendsEventWhenLiveAudioUnavailable(t *testing.T) {
	callManager := calls.NewManager()
	callManager.RegisterSession("session-1")
	sink := &recordingEventSink{}
	callManager.SetEventSink("session-1", sink)

	renderer := callAudioRenderer{server: &server{
		callManager: callManager,
		tts:         fakeCallRendererTTS{audioData: []byte("wav")},
	}}

	if err := renderer.PlaySpeech("session-1", "Working on it."); err != nil {
		t.Fatalf("PlaySpeech returned error: %v", err)
	}

	if len(sink.payloads) != 1 {
		t.Fatalf("expected 1 event payload, got %d", len(sink.payloads))
	}

	event, ok := sink.payloads[0].(calls.PlayAudioEvent)
	if !ok {
		t.Fatalf("expected play audio event payload, got %T", sink.payloads[0])
	}
	if event.Type != "play_audio" {
		t.Fatalf("unexpected event type: %q", event.Type)
	}
	if event.Text != "Working on it." {
		t.Fatalf("unexpected event text: %q", event.Text)
	}
}

func TestCallAudioRendererNotifySpeechStillSendsEventWhenLiveAudioUnavailable(t *testing.T) {
	callManager := calls.NewManager()
	callManager.RegisterSession("session-1")
	sink := &recordingEventSink{}
	callManager.SetEventSink("session-1", sink)

	renderer := callAudioRenderer{server: &server{
		callManager: callManager,
		tts:         fakeCallRendererTTS{audioData: []byte("wav")},
	}}

	if err := renderer.NotifySpeech("session-1", "I have an update.", "The build passed."); err != nil {
		t.Fatalf("NotifySpeech returned error: %v", err)
	}

	if len(sink.payloads) != 1 {
		t.Fatalf("expected 1 event payload, got %d", len(sink.payloads))
	}

	event, ok := sink.payloads[0].(calls.NotifyEvent)
	if !ok {
		t.Fatalf("expected notify event payload, got %T", sink.payloads[0])
	}
	if event.Type != "notify" {
		t.Fatalf("unexpected event type: %q", event.Type)
	}
	if event.Text != "I have an update." {
		t.Fatalf("unexpected notify text: %q", event.Text)
	}
	if event.SummaryText != "The build passed." {
		t.Fatalf("unexpected notify summary text: %q", event.SummaryText)
	}
}
