package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
)

const (
	appConfigFileName    = "config.json"
	DefaultSTTModel      = "parakeet-tdt-0.6b-v3-coreml"
	DefaultTTSModel      = "kitten-tts-mini-0.8"
	defaultAppConfigJSON = "{\n  \"stt_model\": \"" + SpeechProviderMacOS + "/" + DefaultSTTModel + "\",\n  \"tts_model\": \"" + SpeechProviderMacOS + "/" + DefaultTTSModel + "\"\n}\n"
)

type AppConfigStore struct {
	mu            sync.RWMutex
	filePath      string
	raw           map[string]json.RawMessage
	routerProfile string
	sttModel      string
	ttsModel      string
	services      AppServicesConfig
}

type AppConfigSnapshot struct {
	RouterProfile string            `json:"router_profile,omitempty"`
	STTModel      string            `json:"stt_model"`
	TTSModel      string            `json:"tts_model"`
	Services      AppServicesConfig `json:"services,omitempty"`
}

func NewAppConfigStore(dataDir string) (*AppConfigStore, error) {
	configPath := configFilePath(dataDir, appConfigFileName)
	if err := ensureConfigFile(dataDir, appConfigFileName, []byte(defaultAppConfigJSON)); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("read app config: %w", err)
	}

	raw, routerProfile, sttModel, ttsModel, services, err := decodeAppConfig(data)
	if err != nil {
		return nil, fmt.Errorf("decode app config: %w", err)
	}

	return &AppConfigStore{
		filePath:      configPath,
		raw:           raw,
		routerProfile: routerProfile,
		sttModel:      sttModel,
		ttsModel:      ttsModel,
		services:      services,
	}, nil
}

func (s *AppConfigStore) RouterProfile() (string, bool) {
	if s == nil {
		return "", false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if strings.TrimSpace(s.routerProfile) == "" {
		return "", false
	}
	return s.routerProfile, true
}

func (s *AppConfigStore) STTModel() (string, bool) {
	if s == nil {
		return "", false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if strings.TrimSpace(s.sttModel) == "" {
		return "", false
	}
	return s.sttModel, true
}

func (s *AppConfigStore) TTSModel() (string, bool) {
	if s == nil {
		return "", false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if strings.TrimSpace(s.ttsModel) == "" {
		return "", false
	}
	return s.ttsModel, true
}

func (s *AppConfigStore) Services() AppServicesConfig {
	if s == nil {
		return AppServicesConfig{}
	}

	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.services
}

func (s *AppConfigStore) Snapshot() AppConfigSnapshot {
	if s == nil {
		return AppConfigSnapshot{
			STTModel: DefaultSTTSelection().Canonical(),
			TTSModel: DefaultTTSSelection().Canonical(),
			Services: AppServicesConfig{
				Grok: ResolveGrokServiceConfig(AppServicesConfig{}),
			},
		}
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	sttModel := s.sttModel
	if sttModel == "" {
		sttModel = DefaultSTTSelection().Canonical()
	}

	ttsModel := s.ttsModel
	if ttsModel == "" {
		ttsModel = DefaultTTSSelection().Canonical()
	}

	return AppConfigSnapshot{
		RouterProfile: s.routerProfile,
		STTModel:      sttModel,
		TTSModel:      ttsModel,
		Services: AppServicesConfig{
			Grok: ResolveGrokServiceConfig(s.services),
		},
	}
}

func (s *AppConfigStore) SetRouterProfile(name string) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	return s.setRouterProfileLocked(name)
}

func (s *AppConfigStore) UpdateRouterProfileReference(currentName string, nextName string) (bool, error) {
	if s == nil {
		return false, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if normalizeAgentProfileName(currentName) == "" {
		return false, nil
	}
	if normalizeAgentProfileName(s.routerProfile) != normalizeAgentProfileName(currentName) {
		return false, nil
	}

	if err := s.setRouterProfileLocked(nextName); err != nil {
		return false, err
	}
	return true, nil
}

func (s *AppConfigStore) setRouterProfileLocked(name string) error {
	nextRouterProfile := strings.TrimSpace(name)
	nextRaw := cloneRawJSONMap(s.raw)

	if nextRouterProfile == "" {
		delete(nextRaw, "router_profile")
	} else {
		payload, err := json.Marshal(nextRouterProfile)
		if err != nil {
			return fmt.Errorf("marshal router_profile: %w", err)
		}
		nextRaw["router_profile"] = payload
	}

	if err := writeJSONFile(s.filePath, nextRaw); err != nil {
		return err
	}

	s.raw = nextRaw
	s.routerProfile = nextRouterProfile
	return nil
}

func (s *AppConfigStore) ApplyPatch(patch map[string]json.RawMessage) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	nextRaw := cloneRawJSONMap(s.raw)
	nextRouterProfile := s.routerProfile
	nextSTTModel := s.sttModel
	nextTTSModel := s.ttsModel
	nextServices := s.services

	for key, rawValue := range patch {
		switch key {
		case "router_profile":
			value, err := decodeRawOptionalString(key, rawValue)
			if err != nil {
				return err
			}
			nextRouterProfile = value
			if value == "" {
				delete(nextRaw, key)
			} else {
				nextRaw[key], err = json.Marshal(value)
				if err != nil {
					return fmt.Errorf("marshal %s: %w", key, err)
				}
			}
		case "stt_model":
			value, err := decodeValidatedSpeechModelRaw(key, rawValue, SpeechTargetSTT)
			if err != nil {
				return err
			}
			nextSTTModel = value
			if value == "" {
				delete(nextRaw, key)
			} else {
				nextRaw[key], err = json.Marshal(value)
				if err != nil {
					return fmt.Errorf("marshal %s: %w", key, err)
				}
			}
		case "tts_model":
			value, err := decodeValidatedSpeechModelRaw(key, rawValue, SpeechTargetTTS)
			if err != nil {
				return err
			}
			nextTTSModel = value
			if value == "" {
				delete(nextRaw, key)
			} else {
				nextRaw[key], err = json.Marshal(value)
				if err != nil {
					return fmt.Errorf("marshal %s: %w", key, err)
				}
			}
		case "services":
			value, err := decodeRawServicesConfig(rawValue)
			if err != nil {
				return err
			}
			nextServices = value
			if isServicesConfigEmpty(value) {
				delete(nextRaw, key)
			} else {
				nextRaw[key], err = json.Marshal(value)
				if err != nil {
					return fmt.Errorf("marshal %s: %w", key, err)
				}
			}
		default:
			return fmt.Errorf("unknown app config field %q", key)
		}
	}

	if err := writeJSONFile(s.filePath, nextRaw); err != nil {
		return err
	}

	s.raw = nextRaw
	s.routerProfile = nextRouterProfile
	s.sttModel = nextSTTModel
	s.ttsModel = nextTTSModel
	s.services = nextServices
	return nil
}

func decodeAppConfig(data []byte) (map[string]json.RawMessage, string, string, string, AppServicesConfig, error) {
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, "", "", "", AppServicesConfig{}, err
	}
	if decoded == nil {
		decoded = map[string]json.RawMessage{}
	}

	routerProfile, err := decodeOptionalString(decoded, "router_profile")
	if err != nil {
		return nil, "", "", "", AppServicesConfig{}, err
	}
	sttModel, err := decodeValidatedSpeechModel(decoded, "stt_model", SpeechTargetSTT)
	if err != nil {
		return nil, "", "", "", AppServicesConfig{}, err
	}
	ttsModel, err := decodeValidatedSpeechModel(decoded, "tts_model", SpeechTargetTTS)
	if err != nil {
		return nil, "", "", "", AppServicesConfig{}, err
	}
	services, err := decodeOptionalServicesConfig(decoded, "services")
	if err != nil {
		return nil, "", "", "", AppServicesConfig{}, err
	}

	return decoded, routerProfile, sttModel, ttsModel, services, nil
}

func decodeOptionalString(decoded map[string]json.RawMessage, key string) (string, error) {
	rawValue, ok := decoded[key]
	if !ok || string(rawValue) == "null" {
		return "", nil
	}

	var value string
	if err := json.Unmarshal(rawValue, &value); err != nil {
		return "", fmt.Errorf("%s must be a string", key)
	}
	return strings.TrimSpace(value), nil
}

func decodeRawOptionalString(key string, rawValue json.RawMessage) (string, error) {
	if len(rawValue) == 0 || string(rawValue) == "null" {
		return "", nil
	}

	var value string
	if err := json.Unmarshal(rawValue, &value); err != nil {
		return "", fmt.Errorf("%s must be a string", key)
	}
	return strings.TrimSpace(value), nil
}

func decodeValidatedSpeechModel(decoded map[string]json.RawMessage, key string, target SpeechTarget) (string, error) {
	rawValue, ok := decoded[key]
	if !ok {
		return "", nil
	}
	return decodeValidatedSpeechModelRaw(key, rawValue, target)
}

func decodeValidatedSpeechModelRaw(key string, rawValue json.RawMessage, target SpeechTarget) (string, error) {
	value, err := decodeRawOptionalString(key, rawValue)
	if err != nil {
		return "", err
	}
	if value == "" {
		return "", nil
	}

	selection, err := ParseSpeechModelSelection(value)
	if err != nil {
		return "", fmt.Errorf("%s must use <provider>/<model>", key)
	}
	if err := ValidateSpeechModelSelection(selection, target); err != nil {
		return "", err
	}
	return selection.Canonical(), nil
}

func decodeOptionalServicesConfig(decoded map[string]json.RawMessage, key string) (AppServicesConfig, error) {
	rawValue, ok := decoded[key]
	if !ok {
		return AppServicesConfig{}, nil
	}
	return decodeRawServicesConfig(rawValue)
}

func decodeRawServicesConfig(rawValue json.RawMessage) (AppServicesConfig, error) {
	if len(rawValue) == 0 || string(rawValue) == "null" {
		return AppServicesConfig{}, nil
	}

	var value AppServicesConfig
	if err := json.Unmarshal(rawValue, &value); err != nil {
		return AppServicesConfig{}, fmt.Errorf("services must be an object")
	}
	if err := ValidateAppServicesConfig(value); err != nil {
		return AppServicesConfig{}, err
	}
	return value, nil
}

func isServicesConfigEmpty(config AppServicesConfig) bool {
	return isGrokServiceConfigEmpty(config.Grok)
}

func isGrokServiceConfigEmpty(config GrokServiceConfig) bool {
	return config.Enabled == nil &&
		strings.TrimSpace(config.BaseURL) == "" &&
		config.TTS == (GrokTTSServiceConfig{}) &&
		config.STT == (GrokSTTServiceConfig{})
}

func cloneRawJSONMap(source map[string]json.RawMessage) map[string]json.RawMessage {
	cloned := make(map[string]json.RawMessage, len(source))
	for key, value := range source {
		if value == nil {
			cloned[key] = nil
			continue
		}
		cloned[key] = append(json.RawMessage(nil), value...)
	}
	return cloned
}
