package agent_adapters

func Default() map[string]Adapter {
	return map[string]Adapter{
		"codex":    &CodexAdapter{},
		"opencode": &OpencodeAdapter{},
	}
}
