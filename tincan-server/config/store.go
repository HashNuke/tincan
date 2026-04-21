package config

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
)

//go:embed agent_profiles.json
var agentProfilesJSON []byte

//go:embed agent_backends.json
var agentBackendsJSON []byte

type AgentProfileStore struct {
	profiles map[string]AgentProfile
}

type AgentBackendStore struct {
	backends map[string]AgentBackendDefinition
}

func NewAgentProfileStore() (*AgentProfileStore, error) {
	var decoded []AgentProfile
	if err := json.Unmarshal(agentProfilesJSON, &decoded); err != nil {
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

func NewAgentBackendStore() (*AgentBackendStore, error) {
	var decoded map[string]AgentBackendDefinition
	if err := json.Unmarshal(agentBackendsJSON, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent backends: %w", err)
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
