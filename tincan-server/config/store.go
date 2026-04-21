package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	agentProfilesFileName = "agent_profiles.json"
	agentBackendsFileName = "agent_backends.json"
)

type AgentProfileStore struct {
	profiles map[string]AgentProfile
}

type AgentBackendStore struct {
	backends map[string]AgentBackendDefinition
}

func NewAgentProfileStore(dataDir string) (*AgentProfileStore, error) {
	if err := ensureConfigFile(filepath.Join(dataDir, agentProfilesFileName), []byte("[]\n")); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(filepath.Join(dataDir, agentProfilesFileName))
	if err != nil {
		return nil, fmt.Errorf("read agent profiles: %w", err)
	}

	var decoded []AgentProfile
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent profiles: %w", err)
	}

	profiles := make(map[string]AgentProfile, len(decoded))
	for _, profile := range decoded {
		if profile.Name == "" {
			return nil, fmt.Errorf("agent profile name must not be empty")
		}
		if profile.WorkingDirectory == "" {
			return nil, fmt.Errorf("agent profile %q working_directory must not be empty", profile.Name)
		}
		if profile.AgentBackend == "" {
			return nil, fmt.Errorf("agent profile %q agent_backend must not be empty", profile.Name)
		}
		normalizedName := normalizeAgentProfileName(profile.Name)
		if _, exists := profiles[normalizedName]; exists {
			return nil, fmt.Errorf("duplicate agent profile %q", profile.Name)
		}
		profiles[normalizedName] = profile
	}

	return &AgentProfileStore{profiles: profiles}, nil
}

func NewAgentBackendStore(dataDir string) (*AgentBackendStore, error) {
	if err := ensureConfigFile(filepath.Join(dataDir, agentBackendsFileName), []byte("{}\n")); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(filepath.Join(dataDir, agentBackendsFileName))
	if err != nil {
		return nil, fmt.Errorf("read agent backends: %w", err)
	}

	var decoded map[string]AgentBackendDefinition
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent backends: %w", err)
	}
	if decoded == nil {
		decoded = map[string]AgentBackendDefinition{}
	}

	backends := make(map[string]AgentBackendDefinition, len(decoded))
	for name, backend := range decoded {
		if name == "" {
			return nil, fmt.Errorf("agent backend name must not be empty")
		}
		if backend.Type == "" {
			return nil, fmt.Errorf("agent backend %q type must not be empty", name)
		}
		if backend.Options.Model == "" {
			return nil, fmt.Errorf("agent backend %q model must not be empty", name)
		}
		if backend.Options.Agent == "" {
			backend.Options.Agent = "build"
		}
		backends[name] = backend
	}

	return &AgentBackendStore{backends: backends}, nil
}

func (s *AgentProfileStore) List() []AgentProfile {
	result := make([]AgentProfile, 0, len(s.profiles))
	for _, profile := range s.profiles {
		result = append(result, profile)
	}
	return result
}

func (s *AgentProfileStore) Get(name string) (AgentProfile, bool) {
	profile, ok := s.profiles[normalizeAgentProfileName(name)]
	return profile, ok
}

func normalizeAgentProfileName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

func (s *AgentBackendStore) Get(name string) (AgentBackendDefinition, bool) {
	backend, ok := s.backends[name]
	return backend, ok
}

func (s *AgentBackendStore) BackendBaseURL(name string) (string, bool) {
	backend, ok := s.backends[name]
	if !ok {
		return "", false
	}
	return backend.Options.BaseURL, true
}

func ensureConfigFile(path string, defaultContents []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat config file %s: %w", path, err)
	}

	if err := os.WriteFile(path, defaultContents, 0o644); err != nil {
		return fmt.Errorf("create config file %s: %w", path, err)
	}
	return nil
}
