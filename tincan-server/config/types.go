package config

type AgentProfile struct {
	Name             string `json:"name"`
	WorkingDirectory string `json:"working_directory"`
	AgentBackend     string `json:"agent_backend"`
}

type AgentBackendDefinition struct {
	Type    string              `json:"type"`
	Options AgentBackendOptions `json:"options"`
}

type AgentBackendOptions struct {
	ConnectionType string   `json:"connection_type,omitempty"`
	Model          string   `json:"model,omitempty"`
	ModelVariant   string   `json:"model_variant,omitempty"`
	BaseURL        string   `json:"base_url,omitempty"`
	Agent          string   `json:"agent,omitempty"`
	ExtraArgs      []string `json:"extra_args,omitempty"`
}
