package main

import (
	"io"
	"strings"
	"testing"
)

func TestNewSpeechServiceSetForNonDarwinDoesNotConfigureMacOSInference(t *testing.T) {
	appConfig := testAppConfigStore(t, `{
  "stt_model": "macos/parakeet-tdt-0.6b-v3-coreml",
  "tts_model": "macos/kitten-tts-mini-0.8"
}`)

	services, err := newSpeechServiceSetForGOOS(
		appConfig,
		io.Discard,
		envCredentialReader{lookupEnv: func(string) (string, bool) { return "", false }},
		"linux",
	)
	if err != nil {
		t.Fatalf("newSpeechServiceSetForGOOS returned error: %v", err)
	}

	if _, ok := services.runtime.(noopSpeechRuntime); !ok {
		t.Fatalf("expected noop speech runtime on non-macOS host, got %T", services.runtime)
	}

	if _, err := services.stt.transcribe([]byte("test"), "audio/wav"); err == nil || !strings.Contains(err.Error(), "requires macOS host") {
		t.Fatalf("expected non-macOS stt error, got %v", err)
	}

	if _, err := services.tts.synthesize("hello"); err == nil || !strings.Contains(err.Error(), "requires macOS host") {
		t.Fatalf("expected non-macOS tts error, got %v", err)
	}
}

func TestNewSpeechServiceSetForDarwinConfiguresLocalInference(t *testing.T) {
	appConfig := testAppConfigStore(t, `{
  "stt_model": "macos/parakeet-tdt-0.6b-v3-coreml",
  "tts_model": "macos/kitten-tts-mini-0.8"
}`)

	services, err := newSpeechServiceSetForGOOS(
		appConfig,
		io.Discard,
		envCredentialReader{lookupEnv: func(string) (string, bool) { return "", false }},
		"darwin",
	)
	if err != nil {
		t.Fatalf("newSpeechServiceSetForGOOS returned error: %v", err)
	}

	if _, ok := services.runtime.(noopSpeechRuntime); ok {
		t.Fatalf("expected local inference runtime on macOS host")
	}

	if _, ok := services.stt.(*inferenceClient); !ok {
		t.Fatalf("expected macOS stt service to use inference client, got %T", services.stt)
	}

	if _, ok := services.tts.(*inferenceClient); !ok {
		t.Fatalf("expected macOS tts service to use inference client, got %T", services.tts)
	}
}
