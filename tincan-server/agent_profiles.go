package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

//go:embed config/agent_profiles.json
var agentProfilesJSON []byte

type AgentProfile struct {
	Name                string              `json:"name"`
	WorkingDirectory    string              `json:"working_directory"`
	AgentBackend        string              `json:"agent_backend"`
	AgentBackendOptions AgentBackendOptions `json:"agent_backend_options"`
}

type AgentBackendOptions struct {
	Model       string   `json:"model"`
	ModelEffort string   `json:"model_effort,omitempty"`
	BaseURL     string   `json:"base_url,omitempty"`
	Agent       string   `json:"agent,omitempty"`
	ExtraArgs   []string `json:"extra_args,omitempty"`
}

type AgentProfileStore struct {
	profiles map[string]AgentProfile
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
		if profile.AgentBackendOptions.Model == "" {
			return nil, fmt.Errorf("agent profile %q model must not be empty", profile.Name)
		}
		if _, exists := profiles[profile.Name]; exists {
			return nil, fmt.Errorf("duplicate agent profile %q", profile.Name)
		}
		profiles[profile.Name] = profile
	}

	return &AgentProfileStore{profiles: profiles}, nil
}

func (s *AgentProfileStore) List() []AgentProfile {
	result := make([]AgentProfile, 0, len(s.profiles))
	for _, profile := range s.profiles {
		result = append(result, profile)
	}
	return result
}

func (s *AgentProfileStore) Get(name string) (AgentProfile, bool) {
	profile, ok := s.profiles[name]
	return profile, ok
}
