package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
)

const appConfigFileName = "config.json"

type AppConfigStore struct {
	mu            sync.RWMutex
	filePath      string
	raw           map[string]json.RawMessage
	routerProfile string
}

func NewAppConfigStore(dataDir string) (*AppConfigStore, error) {
	configPath := configFilePath(dataDir, appConfigFileName)
	if err := ensureConfigFile(dataDir, appConfigFileName, []byte("{}\n")); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("read app config: %w", err)
	}

	raw, routerProfile, err := decodeAppConfig(data)
	if err != nil {
		return nil, fmt.Errorf("decode app config: %w", err)
	}

	return &AppConfigStore{
		filePath:      configPath,
		raw:           raw,
		routerProfile: routerProfile,
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

func decodeAppConfig(data []byte) (map[string]json.RawMessage, string, error) {
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, "", err
	}
	if decoded == nil {
		decoded = map[string]json.RawMessage{}
	}

	routerProfile := ""
	if rawRouterProfile, ok := decoded["router_profile"]; ok {
		if string(rawRouterProfile) == "null" {
			return decoded, "", nil
		}

		if err := json.Unmarshal(rawRouterProfile, &routerProfile); err != nil {
			return nil, "", fmt.Errorf("router_profile must be a string")
		}
		routerProfile = strings.TrimSpace(routerProfile)
	}

	return decoded, routerProfile, nil
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
