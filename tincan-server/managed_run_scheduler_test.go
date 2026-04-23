package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
	tincanrouter "tincan-server/router"
)

func TestManagedRunSchedulerQueuesFollowUpsAndDispatchesNextBatch(t *testing.T) {
	tempDir := t.TempDir()
	logPath := filepath.Join(tempDir, "stdin.log")
	argsPath := filepath.Join(tempDir, "args.log")
	wrapperPath := filepath.Join(tempDir, "tincan-exec")
	opencodePath := filepath.Join(tempDir, "opencode")

	if err := os.WriteFile(wrapperPath, []byte("#!/bin/sh\nexec \"$@\"\n"), 0o755); err != nil {
		t.Fatalf("write wrapper script: %v", err)
	}
	opencodeScript := "#!/bin/sh\n" +
		"printf '%s\n' \"$*\" >> " + shellQuote(argsPath) + "\n" +
		"printf '%s\n' '---' >> " + shellQuote(logPath) + "\n" +
		"cat >> " + shellQuote(logPath) + "\n" +
		"sleep 0.2\n"
	if err := os.WriteFile(opencodePath, []byte(opencodeScript), 0o755); err != nil {
		t.Fatalf("write fake opencode script: %v", err)
	}

	db, err := gorm.Open(sqlite.Open(filepath.Join(tempDir, "conversations.sqlite")), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite db: %v", err)
	}
	if err := db.AutoMigrate(&conversations.Conversation{}, &conversations.ConversationInput{}, &conversations.Message{}, &conversations.ConversationNote{}); err != nil {
		t.Fatalf("migrate sqlite db: %v", err)
	}
	store := conversations.NewStore(db)

	configDir := filepath.Join(tempDir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "agent_backends.json"), []byte(`{
  "opencode-1": {
    "type": "opencode",
    "options": {
      "connection_type": "command",
      "agent": "build"
    }
  }
}
`), 0o644); err != nil {
		t.Fatalf("write backend config: %v", err)
	}
	backends, err := tincanconfig.NewAgentBackendStore(tempDir)
	if err != nil {
		t.Fatalf("NewAgentBackendStore: %v", err)
	}

	conversation, err := store.CreateConversation(conversations.Conversation{
		DisplayHandle:      "atlas#1",
		AgentProfileName:   "atlas",
		ConversationNumber: 1,
		AgentBackend:       "opencode-1",
		WorkingDirectory:   tempDir,
		Status:             "starting",
	})
	if err != nil {
		t.Fatalf("CreateConversation: %v", err)
	}
	if _, err := store.EnqueueConversationInput(conversation.ID, "First request."); err != nil {
		t.Fatalf("enqueue first input: %v", err)
	}

	scheduler := NewManagedRunScheduler(
		"http://127.0.0.1:4490",
		wrapperPath,
		store,
		backends,
		map[string]agent_adapters.Adapter{"opencode": schedulerTestAdapter{programPath: opencodePath}},
	)

	dispatchResult, err := scheduler.DispatchConversation(conversation.ID, "Atlas work")
	if err != nil {
		t.Fatalf("DispatchConversation returned error: %v", err)
	}
	if !dispatchResult.Started {
		t.Fatalf("expected first dispatch to start")
	}

	secondAttempt, err := scheduler.DispatchConversation(conversation.ID, "")
	if err != nil {
		t.Fatalf("second DispatchConversation returned error: %v", err)
	}
	if secondAttempt.Started {
		t.Fatalf("expected second dispatch attempt to stay queued while child is active")
	}

	if _, err := store.EnqueueConversationInput(conversation.ID, "Second request."); err != nil {
		t.Fatalf("enqueue second input: %v", err)
	}
	if _, err := store.EnqueueConversationInput(conversation.ID, "Third request."); err != nil {
		t.Fatalf("enqueue third input: %v", err)
	}
	if _, _, err := store.BindBackendConversationID(conversation.ID, "backend-1"); err != nil {
		t.Fatalf("BindBackendConversationID: %v", err)
	}

	if err := waitForCondition(2*time.Second, func() bool {
		data, readErr := os.ReadFile(logPath)
		return readErr == nil && strings.Contains(string(data), "First request.")
	}); err != nil {
		t.Fatalf("first batch did not write stdin log: %v", err)
	}

	if err := scheduler.HandleSessionIdle(conversation.ID); err != nil {
		t.Fatalf("HandleSessionIdle returned error: %v", err)
	}

	if err := waitForCondition(2*time.Second, func() bool {
		data, readErr := os.ReadFile(argsPath)
		return readErr == nil && strings.Count(string(data), "\n") >= 2
	}); err != nil {
		t.Fatalf("second batch did not start: %v", err)
	}

	if err := scheduler.HandleSessionIdle(conversation.ID); err != nil {
		t.Fatalf("second HandleSessionIdle returned error: %v", err)
	}

	if err := waitForCondition(2*time.Second, func() bool {
		scheduler.mu.Lock()
		defer scheduler.mu.Unlock()
		return len(scheduler.activeRuns) == 0
	}); err != nil {
		t.Fatalf("managed runs did not drain: %v", err)
	}

	logData, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read stdin log: %v", err)
	}
	logText := string(logData)
	if !strings.Contains(logText, "First request.") {
		t.Fatalf("expected first batch prompt in log, got %q", logText)
	}
	if !strings.Contains(logText, "1. Second request.") || !strings.Contains(logText, "2. Third request.") {
		t.Fatalf("expected batched follow-up prompt in log, got %q", logText)
	}

	argsData, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatalf("read args log: %v", err)
	}
	argsLines := strings.Fields(strings.TrimSpace(string(argsData)))
	if !strings.Contains(string(argsData), "--session backend-1") {
		t.Fatalf("expected follow-up batch to continue existing backend session, got %q", string(argsData))
	}
	if len(argsLines) == 0 {
		t.Fatalf("expected recorded opencode arguments")
	}

	runningInputs, err := store.GetRunningConversationInputs(conversation.ID)
	if err != nil {
		t.Fatalf("GetRunningConversationInputs returned error: %v", err)
	}
	if len(runningInputs) != 0 {
		t.Fatalf("expected no running inputs after second idle, got %+v", runningInputs)
	}

	pendingInputs, err := store.ListPendingConversationInputs(conversation.ID)
	if err != nil {
		t.Fatalf("ListPendingConversationInputs returned error: %v", err)
	}
	if len(pendingInputs) != 0 {
		t.Fatalf("expected no pending inputs after second batch, got %+v", pendingInputs)
	}
}

func waitForCondition(timeout time.Duration, condition func() bool) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return os.ErrDeadlineExceeded
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

type schedulerTestAdapter struct {
	programPath string
}

func (a schedulerTestAdapter) Backend() string {
	return "opencode"
}

func (a schedulerTestAdapter) ValidateBackend(name string, backend tincanconfig.AgentBackendDefinition) error {
	return nil
}

func (a schedulerTestAdapter) SupportsModelDiscovery() bool {
	return false
}

func (a schedulerTestAdapter) ListModels(backend tincanconfig.AgentBackendDefinition) ([]string, error) {
	return nil, nil
}

func (a schedulerTestAdapter) BuildConversationCommand(input agent_adapters.ConversationCommandInput) (agent_adapters.ManagedCommand, error) {
	args := []string{}
	if input.Conversation.BackendConversationID == "" {
		if strings.TrimSpace(input.Title) != "" {
			args = append(args, "--title", input.Title)
		}
	} else {
		args = append(args, "--session", input.Conversation.BackendConversationID)
	}

	stdin := strings.TrimSpace(input.Inputs[0].UserText)
	if len(input.Inputs) > 1 {
		var builder strings.Builder
		builder.WriteString("Queued follow-ups:\n")
		for index, item := range input.Inputs {
			builder.WriteString(strings.TrimSpace(strconv.Itoa(index+1) + ". " + item.UserText))
			if index < len(input.Inputs)-1 {
				builder.WriteString("\n")
			}
		}
		stdin = builder.String()
	}

	return agent_adapters.ManagedCommand{
		Program: a.programPath,
		Args:    args,
		Stdin:   stdin,
	}, nil
}

func (a schedulerTestAdapter) RunRouterPrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt agent_adapters.Prompt, rawTranscript string) (tincanrouter.RouteUserInputResult, error) {
	return tincanrouter.RouteUserInputResult{}, nil
}

func (a schedulerTestAdapter) RunConversationUpdatePrompt(profile tincanconfig.AgentProfile, backend tincanconfig.AgentBackendDefinition, prompt agent_adapters.Prompt, rawUpdate string) (tincanrouter.ProcessConversationUpdateResult, error) {
	return tincanrouter.ProcessConversationUpdateResult{}, nil
}
