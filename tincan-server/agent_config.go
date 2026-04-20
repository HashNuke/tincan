package main

import (
	_ "embed"
	"encoding/json"
	"fmt"

	tincanconfig "tincan-server/config"
)

//go:embed config/agent_profiles.json
var agentProfilesJSON []byte

//go:embed config/agent_backends.json
var agentBackendsJSON []byte

type AgentProfileStore struct {
	profiles map[string]tincanconfig.AgentProfile
}

type AgentBackendStore struct {
	backends map[string]tincanconfig.AgentBackendDefinition
}

func NewAgentProfileStore() (*AgentProfileStore, error) {
	var decoded []tincanconfig.AgentProfile
	if err := json.Unmarshal(agentProfilesJSON, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent profiles: %w", err)
	}

	profiles := make(map[string]tincanconfig.AgentProfile, len(decoded))
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
		if _, exists := profiles[profile.Name]; exists {
			return nil, fmt.Errorf("duplicate agent profile %q", profile.Name)
		}
		profiles[profile.Name] = profile
	}

	return &AgentProfileStore{profiles: profiles}, nil
}

func NewAgentBackendStore() (*AgentBackendStore, error) {
	var decoded map[string]tincanconfig.AgentBackendDefinition
	if err := json.Unmarshal(agentBackendsJSON, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent backends: %w", err)
	}

	backends := make(map[string]tincanconfig.AgentBackendDefinition, len(decoded))
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

func (s *AgentProfileStore) List() []tincanconfig.AgentProfile {
	result := make([]tincanconfig.AgentProfile, 0, len(s.profiles))
	for _, profile := range s.profiles {
		result = append(result, profile)
	}
	return result
}

func (s *AgentProfileStore) Get(name string) (tincanconfig.AgentProfile, bool) {
	profile, ok := s.profiles[name]
	return profile, ok
}

func (s *AgentBackendStore) Get(name string) (tincanconfig.AgentBackendDefinition, bool) {
	backend, ok := s.backends[name]
	return backend, ok
}
