package main

func DefaultAgentAdapters() map[string]AgentAdapter {
	return map[string]AgentAdapter{
		"codex":    &CodexAdapter{},
		"opencode": &OpencodeAdapter{httpClient: nil},
	}
}
