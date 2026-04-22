package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	tincanconfig "tincan-server/config"
)

const defaultMacOSTTSVoice = "alba"

type speechToTextService interface {
	transcribe(audioData []byte, contentType string) (string, error)
}

type textToSpeechService interface {
	synthesize(text string) ([]byte, error)
}

type speechRuntime interface {
	EnsureRunning(ctx context.Context) error
	Shutdown()
}

type speechServiceSet struct {
	runtime speechRuntime
	stt     speechToTextService
	tts     textToSpeechService
}

type noopSpeechRuntime struct{}

type unsupportedSpeechToTextService struct {
	selection tincanconfig.SpeechModelSelection
}

type unsupportedTextToSpeechService struct {
	selection tincanconfig.SpeechModelSelection
}

func newSpeechServiceSet(
	appConfig *tincanconfig.AppConfigStore,
	output io.Writer,
	credentials serviceCredentialReader,
) (speechServiceSet, error) {
	sttSelection := configuredSTTSelection(appConfig)
	ttsSelection := configuredTTSSelection(appConfig)
	services := appConfigServices(appConfig)

	result := speechServiceSet{
		runtime: noopSpeechRuntime{},
	}

	var localInference *inferenceClient
	if sttSelection.Provider == tincanconfig.SpeechProviderMacOS || ttsSelection.Provider == tincanconfig.SpeechProviderMacOS {
		localInference = &inferenceClient{
			socketPath: inferenceSocketPath(),
			sttModel:   inferenceModelForSelection(sttSelection, defaultBundledSTTModel),
			ttsModel:   inferenceModelForSelection(ttsSelection, defaultBundledTTSModel),
			ttsVoice:   defaultMacOSTTSVoice,
		}
		result.runtime = newInferenceSupervisor(inferenceSocketPath(), appConfig, output)
	}

	sttService, err := buildSpeechToTextService(sttSelection, services, credentials, localInference)
	if err != nil {
		return speechServiceSet{}, err
	}
	ttsService, err := buildTextToSpeechService(ttsSelection, services, credentials, localInference)
	if err != nil {
		return speechServiceSet{}, err
	}

	result.stt = sttService
	result.tts = ttsService
	return result, nil
}

func (noopSpeechRuntime) EnsureRunning(context.Context) error { return nil }
func (noopSpeechRuntime) Shutdown()                           {}

func (s unsupportedSpeechToTextService) transcribe(_ []byte, _ string) (string, error) {
	return "", fmt.Errorf("stt provider %q is not implemented", s.selection.Canonical())
}

func (s unsupportedTextToSpeechService) synthesize(_ string) ([]byte, error) {
	return nil, fmt.Errorf("tts provider %q is not implemented", s.selection.Canonical())
}

func buildSpeechToTextService(
	selection tincanconfig.SpeechModelSelection,
	services tincanconfig.AppServicesConfig,
	credentials serviceCredentialReader,
	localInference *inferenceClient,
) (speechToTextService, error) {
	switch selection.Provider {
	case tincanconfig.SpeechProviderMacOS:
		if localInference == nil {
			return nil, fmt.Errorf("stt selection %q requires local inference", selection.Canonical())
		}
		return localInference, nil
	case tincanconfig.SpeechProviderGrok:
		return newGrokSpeechClient(services, credentials, selection, configuredTTSSelection(nil)), nil
	case tincanconfig.SpeechProviderGemini:
		return unsupportedSpeechToTextService{selection: selection}, nil
	default:
		return nil, fmt.Errorf("unsupported stt provider %q", selection.Provider)
	}
}

func buildTextToSpeechService(
	selection tincanconfig.SpeechModelSelection,
	services tincanconfig.AppServicesConfig,
	credentials serviceCredentialReader,
	localInference *inferenceClient,
) (textToSpeechService, error) {
	switch selection.Provider {
	case tincanconfig.SpeechProviderMacOS:
		if localInference == nil {
			return nil, fmt.Errorf("tts selection %q requires local inference", selection.Canonical())
		}
		return localInference, nil
	case tincanconfig.SpeechProviderGrok:
		return newGrokSpeechClient(services, credentials, configuredSTTSelection(nil), selection), nil
	case tincanconfig.SpeechProviderGemini:
		return unsupportedTextToSpeechService{selection: selection}, nil
	default:
		return nil, fmt.Errorf("unsupported tts provider %q", selection.Provider)
	}
}

func configuredSTTSelection(appConfig *tincanconfig.AppConfigStore) tincanconfig.SpeechModelSelection {
	if appConfig != nil {
		if raw, ok := appConfig.STTModel(); ok {
			if selection, err := tincanconfig.ParseSpeechModelSelection(raw); err == nil && strings.TrimSpace(selection.Provider) != "" {
				return selection
			}
		}
	}
	return tincanconfig.DefaultSTTSelection()
}

func configuredTTSSelection(appConfig *tincanconfig.AppConfigStore) tincanconfig.SpeechModelSelection {
	if appConfig != nil {
		if raw, ok := appConfig.TTSModel(); ok {
			if selection, err := tincanconfig.ParseSpeechModelSelection(raw); err == nil && strings.TrimSpace(selection.Provider) != "" {
				return selection
			}
		}
	}
	return tincanconfig.DefaultTTSSelection()
}

func appConfigServices(appConfig *tincanconfig.AppConfigStore) tincanconfig.AppServicesConfig {
	if appConfig == nil {
		return tincanconfig.AppServicesConfig{}
	}
	return appConfig.Services()
}

func inferenceModelForSelection(selection tincanconfig.SpeechModelSelection, fallback string) string {
	if selection.Provider == tincanconfig.SpeechProviderMacOS && strings.TrimSpace(selection.Model) != "" {
		return selection.Model
	}
	return fallback
}
