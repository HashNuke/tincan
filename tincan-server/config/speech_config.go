package config

import (
	"fmt"
	"net/url"
	"strings"
)

const (
	SpeechProviderMacOS  = "macos"
	SpeechProviderGrok   = "grok"
	SpeechProviderGemini = "gemini"

	DefaultGrokBaseURL       = "https://api.x.ai/v1"
	DefaultGrokTTSVoiceID    = "eve"
	DefaultGrokTTSLanguage   = "en"
	DefaultGrokTTSCodec      = "wav"
	DefaultGrokTTSSampleRate = 44100
)

type SpeechTarget string

const (
	SpeechTargetSTT SpeechTarget = "stt_model"
	SpeechTargetTTS SpeechTarget = "tts_model"
)

type SpeechModelSelection struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
}

type AppServicesConfig struct {
	Grok GrokServiceConfig `json:"grok,omitempty"`
}

type GrokServiceConfig struct {
	Enabled *bool                `json:"enabled,omitempty"`
	BaseURL string               `json:"base_url,omitempty"`
	TTS     GrokTTSServiceConfig `json:"tts,omitempty"`
	STT     GrokSTTServiceConfig `json:"stt,omitempty"`
}

type GrokTTSServiceConfig struct {
	VoiceID      string                `json:"voice_id,omitempty"`
	Language     string                `json:"language,omitempty"`
	OutputFormat GrokAudioOutputFormat `json:"output_format,omitempty"`
}

type GrokSTTServiceConfig struct {
	Language string `json:"language,omitempty"`
}

type GrokAudioOutputFormat struct {
	Codec      string `json:"codec,omitempty"`
	SampleRate int    `json:"sample_rate,omitempty"`
	BitRate    int    `json:"bit_rate,omitempty"`
}

func DefaultSTTSelection() SpeechModelSelection {
	return SpeechModelSelection{
		Provider: SpeechProviderMacOS,
		Model:    DefaultSTTModel,
	}
}

func DefaultTTSSelection() SpeechModelSelection {
	return SpeechModelSelection{
		Provider: SpeechProviderMacOS,
		Model:    DefaultTTSModel,
	}
}

func (s SpeechModelSelection) Canonical() string {
	if strings.TrimSpace(s.Provider) == "" || strings.TrimSpace(s.Model) == "" {
		return ""
	}
	return s.Provider + "/" + s.Model
}

func ParseSpeechModelSelection(raw string) (SpeechModelSelection, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return SpeechModelSelection{}, nil
	}

	if !strings.Contains(trimmed, "/") {
		return SpeechModelSelection{
			Provider: SpeechProviderMacOS,
			Model:    trimmed,
		}, nil
	}

	parts := strings.SplitN(trimmed, "/", 2)
	provider := strings.ToLower(strings.TrimSpace(parts[0]))
	model := strings.TrimSpace(parts[1])
	if provider == "" || model == "" {
		return SpeechModelSelection{}, fmt.Errorf("speech model must use <provider>/<model>")
	}

	return SpeechModelSelection{
		Provider: provider,
		Model:    model,
	}, nil
}

func ValidateSpeechModelSelection(selection SpeechModelSelection, target SpeechTarget) error {
	if strings.TrimSpace(selection.Provider) == "" || strings.TrimSpace(selection.Model) == "" {
		return fmt.Errorf("%s must use <provider>/<model>", target)
	}

	switch selection.Provider {
	case SpeechProviderMacOS:
		return nil
	case SpeechProviderGrok:
		switch target {
		case SpeechTargetSTT:
			if selection.Model != "grok-stt-v1" {
				return fmt.Errorf("%s only supports grok/grok-stt-v1 right now", target)
			}
		case SpeechTargetTTS:
			if selection.Model != "grok-tts-v1" {
				return fmt.Errorf("%s only supports grok/grok-tts-v1 right now", target)
			}
		}
		return nil
	case SpeechProviderGemini:
		return nil
	default:
		return fmt.Errorf("unsupported speech provider %q in %s", selection.Provider, target)
	}
}

func ResolveGrokServiceConfig(config AppServicesConfig) GrokServiceConfig {
	resolved := config.Grok
	if strings.TrimSpace(resolved.BaseURL) == "" {
		resolved.BaseURL = DefaultGrokBaseURL
	}
	if strings.TrimSpace(resolved.TTS.VoiceID) == "" {
		resolved.TTS.VoiceID = DefaultGrokTTSVoiceID
	}
	if strings.TrimSpace(resolved.TTS.Language) == "" {
		resolved.TTS.Language = DefaultGrokTTSLanguage
	}
	if strings.TrimSpace(resolved.TTS.OutputFormat.Codec) == "" {
		resolved.TTS.OutputFormat.Codec = DefaultGrokTTSCodec
	}
	if resolved.TTS.OutputFormat.SampleRate <= 0 {
		resolved.TTS.OutputFormat.SampleRate = DefaultGrokTTSSampleRate
	}
	return resolved
}

func ValidateAppServicesConfig(config AppServicesConfig) error {
	return ValidateGrokServiceConfig(config.Grok)
}

func ValidateGrokServiceConfig(config GrokServiceConfig) error {
	baseURL := strings.TrimSpace(config.BaseURL)
	if baseURL != "" {
		parsed, err := url.Parse(baseURL)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return fmt.Errorf("services.grok.base_url must be a valid absolute URL")
		}
	}

	codec := strings.ToLower(strings.TrimSpace(config.TTS.OutputFormat.Codec))
	if codec != "" && codec != "wav" {
		return fmt.Errorf("services.grok.tts.output_format.codec must be wav for now")
	}

	if config.TTS.OutputFormat.SampleRate < 0 {
		return fmt.Errorf("services.grok.tts.output_format.sample_rate must be positive")
	}
	if config.TTS.OutputFormat.BitRate < 0 {
		return fmt.Errorf("services.grok.tts.output_format.bit_rate must be positive")
	}

	return nil
}
