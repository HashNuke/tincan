package main

import (
	"io"
	"net/http"
	"strings"
	"testing"

	tincanconfig "tincan-server/config"
)

func TestGrokSpeechClientSynthesizeSkipsHTTPWhenAPIKeyIsUnavailable(t *testing.T) {
	transport := &recordingRoundTripper{}
	client := newGrokSpeechClient(
		tincanconfig.AppServicesConfig{},
		newServiceCredentialStore(nil),
		configuredSTTSelection(nil),
		tincanconfig.SpeechModelSelection{Provider: "grok", Model: "grok-tts-v1"},
	)
	client.httpClient = &http.Client{Transport: transport}

	_, err := client.synthesize("hello")
	if err == nil {
		t.Fatal("expected synthesize to fail when GROK_API_KEY is unavailable")
	}
	if !strings.Contains(err.Error(), "lookup GROK_API_KEY") {
		t.Fatalf("expected lookup error, got %v", err)
	}
	if transport.callCount != 0 {
		t.Fatalf("expected no HTTP requests, got %d", transport.callCount)
	}
}

func TestGrokSpeechClientTranscribeSkipsHTTPWhenAPIKeyIsUnavailable(t *testing.T) {
	transport := &recordingRoundTripper{}
	client := newGrokSpeechClient(
		tincanconfig.AppServicesConfig{},
		newServiceCredentialStore(nil),
		tincanconfig.SpeechModelSelection{Provider: "grok", Model: "grok-stt-v1"},
		configuredTTSSelection(nil),
	)
	client.httpClient = &http.Client{Transport: transport}

	_, err := client.transcribe([]byte("audio"), "audio/wav")
	if err == nil {
		t.Fatal("expected transcribe to fail when GROK_API_KEY is unavailable")
	}
	if !strings.Contains(err.Error(), "lookup GROK_API_KEY") {
		t.Fatalf("expected lookup error, got %v", err)
	}
	if transport.callCount != 0 {
		t.Fatalf("expected no HTTP requests, got %d", transport.callCount)
	}
}

type recordingRoundTripper struct {
	callCount int
}

func (r *recordingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	r.callCount++
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(strings.NewReader(`{}`)),
	}, nil
}
