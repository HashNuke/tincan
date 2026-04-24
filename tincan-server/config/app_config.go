package config

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
)

const (
	appConfigFileName    = "config.json"
	DefaultSTTModel      = "parakeet-tdt-0.6b-v3-coreml"
	DefaultTTSModel      = "kitten-tts-mini-0.8"
	DefaultConnectTo     = "local"
	defaultAppConfigJSON = "{\n  \"stt_model\": \"" + SpeechProviderMacOS + "/" + DefaultSTTModel + "\",\n  \"tts_model\": \"" + SpeechProviderMacOS + "/" + DefaultTTSModel + "\"\n}\n"
)

type AppConfigStore struct {
	mu            sync.RWMutex
	filePath      string
	raw           map[string]json.RawMessage
	routerProfile string
	connectTo     string
	serverURL     string
	sttModel      string
	ttsModel      string
	services      AppServicesConfig
	tailscale     AppConfigTailscale
}

type AppConfigTailscale struct {
	Enabled bool   `json:"enabled,omitempty"`
	NodeURL string `json:"node_url,omitempty"`
}

type AppConfigSnapshot struct {
	RouterProfile string             `json:"router_profile,omitempty"`
	ConnectTo     string             `json:"connect_to"`
	ServerURL     string             `json:"server_url,omitempty"`
	STTModel      string             `json:"stt_model"`
	TTSModel      string             `json:"tts_model"`
	Services      AppServicesConfig  `json:"services,omitempty"`
	Tailscale     AppConfigTailscale `json:"tailscale,omitempty"`
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

	raw, routerProfile, connectTo, serverURL, sttModel, ttsModel, services, tailscale, err := decodeAppConfig(data)
	if err != nil {
		return nil, fmt.Errorf("decode app config: %w", err)
	}

	return &AppConfigStore{
		filePath:      configPath,
		raw:           raw,
		routerProfile: routerProfile,
		connectTo:     connectTo,
		serverURL:     serverURL,
		sttModel:      sttModel,
		ttsModel:      ttsModel,
		services:      services,
		tailscale:     tailscale,
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

func (s *AppConfigStore) ServerURL() (string, bool) {
	if s == nil {
		return "", false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if strings.TrimSpace(s.serverURL) == "" {
		return "", false
	}
	return s.serverURL, true
}

func (s *AppConfigStore) TailscaleEnabled() bool {
	if s == nil {
		return false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.tailscale.Enabled
}

func (s *AppConfigStore) TailscaleNodeURL() (string, bool) {
	if s == nil {
		return "", false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	if strings.TrimSpace(s.tailscale.NodeURL) == "" {
		return "", false
	}
	return s.tailscale.NodeURL, true
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
			ConnectTo: DefaultConnectTo,
			STTModel:  DefaultSTTSelection().Canonical(),
			TTSModel:  DefaultTTSSelection().Canonical(),
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
	connectTo := s.connectTo
	if connectTo == "" {
		connectTo = DefaultConnectTo
	}

	return AppConfigSnapshot{
		RouterProfile: s.routerProfile,
		ConnectTo:     connectTo,
		ServerURL:     s.serverURL,
		STTModel:      sttModel,
		TTSModel:      ttsModel,
		Services: AppServicesConfig{
			Grok: ResolveGrokServiceConfig(s.services),
		},
		Tailscale: s.tailscale,
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

func (s *AppConfigStore) SetServerURL(value string) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	serverURL, err := validateServerURL(value)
	if err != nil {
		return err
	}
	nextRaw := cloneRawJSONMap(s.raw)
	if serverURL == "" {
		delete(nextRaw, "server_url")
	} else if nextRaw["server_url"], err = json.Marshal(serverURL); err != nil {
		return fmt.Errorf("marshal server_url: %w", err)
	}
	if err := writeJSONFile(s.filePath, nextRaw); err != nil {
		return err
	}
	s.raw = nextRaw
	s.serverURL = serverURL
	return nil
}

func (s *AppConfigStore) SetTailscaleEnabled(value bool) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	nextTailscale := s.tailscale
	nextTailscale.Enabled = value
	return s.setTailscaleLocked(nextTailscale)
}

func (s *AppConfigStore) SetTailscaleNodeURL(value string) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	nodeURL, err := validateTailscaleNodeURL(value)
	if err != nil {
		return err
	}
	nextTailscale := s.tailscale
	nextTailscale.NodeURL = nodeURL
	return s.setTailscaleLocked(nextTailscale)
}

func (s *AppConfigStore) SetTailscaleBootstrapResult(nodeURL string) error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	validNodeURL, err := validateTailscaleNodeURL(nodeURL)
	if err != nil {
		return err
	}
	return s.setTailscaleLocked(AppConfigTailscale{
		Enabled: true,
		NodeURL: validNodeURL,
	})
}

func (s *AppConfigStore) SetTailscaleDisabled() error {
	if s == nil {
		return fmt.Errorf("app config store is unavailable")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	nextTailscale := s.tailscale
	nextTailscale.Enabled = false
	return s.setTailscaleLocked(nextTailscale)
}

func (s *AppConfigStore) setTailscaleLocked(value AppConfigTailscale) error {
	nextRaw := cloneRawJSONMap(s.raw)
	if value == (AppConfigTailscale{}) {
		delete(nextRaw, "tailscale")
	} else {
		payload, err := json.Marshal(value)
		if err != nil {
			return fmt.Errorf("marshal tailscale: %w", err)
		}
		nextRaw["tailscale"] = payload
	}
	if err := writeJSONFile(s.filePath, nextRaw); err != nil {
		return err
	}
	s.raw = nextRaw
	s.tailscale = value
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
	nextConnectTo := s.connectTo
	nextServerURL := s.serverURL
	nextSTTModel := s.sttModel
	nextTTSModel := s.ttsModel
	nextServices := s.services
	nextTailscale := s.tailscale

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
		case "connect_to":
			value, err := decodeRawConnectTo(rawValue)
			if err != nil {
				return err
			}
			nextConnectTo = value
			if value == "" || value == DefaultConnectTo {
				delete(nextRaw, key)
			} else {
				nextRaw[key], err = json.Marshal(value)
				if err != nil {
					return fmt.Errorf("marshal %s: %w", key, err)
				}
			}
		case "server_url":
			value, err := decodeRawOptionalString(key, rawValue)
			if err != nil {
				return err
			}
			value, err = validateServerURL(value)
			if err != nil {
				return err
			}
			nextServerURL = value
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
		case "tailscale":
			value, err := decodeRawTailscaleConfig(rawValue)
			if err != nil {
				return err
			}
			nextTailscale = value
			if value == (AppConfigTailscale{}) {
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

	if nextConnectTo == "remote" && strings.TrimSpace(nextServerURL) == "" {
		return fmt.Errorf("connect_to remote requires server_url")
	}

	if err := writeJSONFile(s.filePath, nextRaw); err != nil {
		return err
	}

	s.raw = nextRaw
	s.routerProfile = nextRouterProfile
	s.connectTo = nextConnectTo
	s.serverURL = nextServerURL
	s.sttModel = nextSTTModel
	s.ttsModel = nextTTSModel
	s.services = nextServices
	s.tailscale = nextTailscale
	return nil
}

func decodeAppConfig(data []byte) (map[string]json.RawMessage, string, string, string, string, string, AppServicesConfig, AppConfigTailscale, error) {
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	if decoded == nil {
		decoded = map[string]json.RawMessage{}
	}

	routerProfile, err := decodeOptionalString(decoded, "router_profile")
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	connectTo, err := decodeOptionalConnectTo(decoded, "connect_to")
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	serverURL, err := decodeValidatedServerURL(decoded, "server_url")
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	if connectTo == "remote" && serverURL == "" {
		connectTo = DefaultConnectTo
	}
	sttModel, err := decodeValidatedSpeechModel(decoded, "stt_model", SpeechTargetSTT)
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	ttsModel, err := decodeValidatedSpeechModel(decoded, "tts_model", SpeechTargetTTS)
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	services, err := decodeOptionalServicesConfig(decoded, "services")
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}
	tailscale, err := decodeOptionalTailscaleConfig(decoded, "tailscale")
	if err != nil {
		return nil, "", "", "", "", "", AppServicesConfig{}, AppConfigTailscale{}, err
	}

	return decoded, routerProfile, connectTo, serverURL, sttModel, ttsModel, services, tailscale, nil
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

func decodeOptionalConnectTo(decoded map[string]json.RawMessage, key string) (string, error) {
	rawValue, ok := decoded[key]
	if !ok {
		return DefaultConnectTo, nil
	}
	return decodeRawConnectTo(rawValue)
}

func decodeRawConnectTo(rawValue json.RawMessage) (string, error) {
	value, err := decodeRawOptionalString("connect_to", rawValue)
	if err != nil {
		return "", err
	}
	if value == "" {
		return DefaultConnectTo, nil
	}
	switch value {
	case "local", "remote":
		return value, nil
	default:
		return "", fmt.Errorf("connect_to must be local or remote")
	}
}

func decodeValidatedServerURL(decoded map[string]json.RawMessage, key string) (string, error) {
	rawValue, ok := decoded[key]
	if !ok {
		return "", nil
	}
	value, err := decodeRawOptionalString(key, rawValue)
	if err != nil {
		return "", err
	}
	return validateServerURL(value)
}

func validateServerURL(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", nil
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", fmt.Errorf("server_url must be a full http or https URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("server_url must use http or https")
	}
	if strings.TrimSpace(parsed.Hostname()) == "" {
		return "", fmt.Errorf("server_url must include a host")
	}
	return trimmed, nil
}

func decodeOptionalTailscaleConfig(decoded map[string]json.RawMessage, key string) (AppConfigTailscale, error) {
	rawValue, ok := decoded[key]
	if !ok {
		return AppConfigTailscale{}, nil
	}
	return decodeRawTailscaleConfig(rawValue)
}

func decodeRawTailscaleConfig(rawValue json.RawMessage) (AppConfigTailscale, error) {
	if len(rawValue) == 0 || string(rawValue) == "null" {
		return AppConfigTailscale{}, nil
	}

	var value AppConfigTailscale
	if err := json.Unmarshal(rawValue, &value); err != nil {
		return AppConfigTailscale{}, fmt.Errorf("tailscale must be an object")
	}
	nodeURL, err := validateTailscaleNodeURL(value.NodeURL)
	if err != nil {
		return AppConfigTailscale{}, err
	}
	value.NodeURL = nodeURL
	return value, nil
}

func validateTailscaleNodeURL(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", nil
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return "", fmt.Errorf("tailscale.node_url must be a full https URL")
	}
	if parsed.Scheme != "https" {
		return "", fmt.Errorf("tailscale.node_url must use https")
	}
	if strings.TrimSpace(parsed.Hostname()) == "" {
		return "", fmt.Errorf("tailscale.node_url must include a host")
	}
	if parsed.Port() != "" {
		return "", fmt.Errorf("tailscale.node_url must not include an explicit port")
	}
	return trimmed, nil
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
