package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"tincan-server/agent_adapters"
	tincanconfig "tincan-server/config"
	"tincan-server/conversations"
)

type ManagedDispatchResult struct {
	Started bool
}

type managedRunState struct {
	command      *exec.Cmd
	dispatchID   string
	idleReceived bool
	failed       bool
	failureText  string
}

type ManagedRunScheduler struct {
	mu             sync.Mutex
	serverURL      string
	tincanExecPath string
	conversations  *conversations.Store
	backends       *tincanconfig.AgentBackendStore
	agentAdapters  map[string]agent_adapters.Adapter
	stdout         io.Writer
	stderr         io.Writer
	activeRuns     map[string]*managedRunState
}

func NewManagedRunScheduler(
	serverURL string,
	tincanExecPath string,
	conversationsStore *conversations.Store,
	backends *tincanconfig.AgentBackendStore,
	agentAdapters map[string]agent_adapters.Adapter,
) *ManagedRunScheduler {
	return &ManagedRunScheduler{
		serverURL:      strings.TrimSpace(serverURL),
		tincanExecPath: strings.TrimSpace(tincanExecPath),
		conversations:  conversationsStore,
		backends:       backends,
		agentAdapters:  agentAdapters,
		stdout:         os.Stdout,
		stderr:         os.Stderr,
		activeRuns:     make(map[string]*managedRunState),
	}
}

func (s *ManagedRunScheduler) DispatchConversation(conversationID string, title string) (ManagedDispatchResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.activeRuns[conversationID]; ok {
		return ManagedDispatchResult{Started: false}, nil
	}

	conversation, ok, err := s.conversations.GetConversationByID(conversationID)
	if err != nil {
		return ManagedDispatchResult{}, err
	}
	if !ok {
		return ManagedDispatchResult{}, fmt.Errorf("conversation %q not found", conversationID)
	}

	backend, ok := s.backends.Get(conversation.AgentBackend)
	if !ok {
		return ManagedDispatchResult{}, fmt.Errorf("unknown agent backend %q", conversation.AgentBackend)
	}

	adapter, ok := s.agentAdapters[backend.Type]
	if !ok {
		return ManagedDispatchResult{}, fmt.Errorf("no adapter registered for backend type %q", backend.Type)
	}

	inputs, dispatchID, err := s.conversations.DrainPendingConversationInputs(conversationID)
	if err != nil {
		return ManagedDispatchResult{}, err
	}
	if len(inputs) == 0 {
		return ManagedDispatchResult{Started: false}, nil
	}

	managedCommand, err := adapter.BuildConversationCommand(agent_adapters.ConversationCommandInput{
		Conversation: conversation,
		Backend:      backend,
		Title:        title,
		Inputs:       inputs,
	})
	if err != nil {
		_ = s.conversations.MarkConversationDispatchFailed(conversationID, dispatchID, err.Error())
		_, _ = s.conversations.UpdateConversationStatus(conversationID, "failed")
		return ManagedDispatchResult{}, fmt.Errorf("build managed command: %w", err)
	}

	if strings.TrimSpace(s.tincanExecPath) == "" {
		_ = s.conversations.MarkConversationDispatchFailed(conversationID, dispatchID, "tincan-exec is not configured")
		_, _ = s.conversations.UpdateConversationStatus(conversationID, "failed")
		return ManagedDispatchResult{}, fmt.Errorf("tincan-exec is not configured")
	}

	args := append([]string{managedCommand.Program}, managedCommand.Args...)
	command := exec.Command(s.tincanExecPath, args...)
	command.Dir = conversation.WorkingDirectory
	command.Stdin = strings.NewReader(managedCommand.Stdin)
	command.Stdout = s.stdout
	command.Stderr = s.stderr
	command.Env = append(os.Environ(),
		"TINCAN_SERVER="+s.serverURL,
		"TINCAN_CONVERSATION_ID="+conversation.ID,
	)

	if _, err := s.conversations.UpdateConversationStatus(conversationID, "busy"); err != nil {
		_ = s.conversations.MarkConversationDispatchFailed(conversationID, dispatchID, err.Error())
		return ManagedDispatchResult{}, err
	}

	if err := command.Start(); err != nil {
		_ = s.conversations.MarkConversationDispatchFailed(conversationID, dispatchID, err.Error())
		_, _ = s.conversations.UpdateConversationStatus(conversationID, "failed")
		return ManagedDispatchResult{}, fmt.Errorf("start managed command: %w", err)
	}

	log.Printf(
		"managed conversation dispatch started: conversation_id=%q handle=%q dispatch_id=%q pid=%d command=%q",
		conversation.ID,
		conversation.DisplayHandle,
		dispatchID,
		command.Process.Pid,
		strings.Join(append([]string{s.tincanExecPath}, args...), " "),
	)

	s.activeRuns[conversationID] = &managedRunState{
		command:    command,
		dispatchID: dispatchID,
	}

	go s.waitForExit(conversationID, command)
	return ManagedDispatchResult{Started: true}, nil
}

func (s *ManagedRunScheduler) HandleSessionIdle(conversationID string) error {
	dispatchID, ok, err := s.runningDispatchID(conversationID)
	if err != nil {
		return err
	}
	if !ok {
		return nil
	}

	s.mu.Lock()
	if state, exists := s.activeRuns[conversationID]; exists {
		state.idleReceived = true
	}
	s.mu.Unlock()

	if err := s.conversations.MarkConversationDispatchCompleted(conversationID, dispatchID); err != nil {
		return err
	}
	_, err = s.conversations.UpdateConversationStatus(conversationID, "running")
	return err
}

func (s *ManagedRunScheduler) HandleSessionError(conversationID string, errorText string) error {
	dispatchID, ok, err := s.runningDispatchID(conversationID)
	if err != nil {
		return err
	}
	if !ok {
		return nil
	}

	trimmedError := strings.TrimSpace(errorText)
	if trimmedError == "" {
		trimmedError = "managed conversation run failed"
	}

	s.mu.Lock()
	if state, exists := s.activeRuns[conversationID]; exists {
		state.failed = true
		state.failureText = trimmedError
	}
	s.mu.Unlock()

	if err := s.conversations.MarkConversationDispatchFailed(conversationID, dispatchID, trimmedError); err != nil {
		return err
	}
	_, err = s.conversations.UpdateConversationStatus(conversationID, "failed")
	return err
}

func (s *ManagedRunScheduler) runningDispatchID(conversationID string) (string, bool, error) {
	s.mu.Lock()
	if state, ok := s.activeRuns[conversationID]; ok && strings.TrimSpace(state.dispatchID) != "" {
		dispatchID := state.dispatchID
		s.mu.Unlock()
		return dispatchID, true, nil
	}
	s.mu.Unlock()

	inputs, err := s.conversations.GetRunningConversationInputs(conversationID)
	if err != nil {
		return "", false, err
	}
	if len(inputs) == 0 || strings.TrimSpace(inputs[0].DispatchID) == "" {
		return "", false, nil
	}
	return inputs[0].DispatchID, true, nil
}

func (s *ManagedRunScheduler) waitForExit(conversationID string, command *exec.Cmd) {
	err := command.Wait()

	s.mu.Lock()
	state, ok := s.activeRuns[conversationID]
	if ok && state.command == command {
		delete(s.activeRuns, conversationID)
	} else {
		state = nil
	}
	s.mu.Unlock()

	if state == nil {
		return
	}

	if state.failed {
		return
	}

	if !state.idleReceived {
		failureText := strings.TrimSpace(state.failureText)
		if failureText == "" {
			if err != nil {
				failureText = fmt.Sprintf("managed command exited before session.idle: %v", err)
			} else {
				failureText = "managed command exited before session.idle"
			}
		}
		if markErr := s.conversations.MarkConversationDispatchFailed(conversationID, state.dispatchID, failureText); markErr != nil {
			log.Printf("failed to mark managed dispatch failed: conversation_id=%q dispatch_id=%q err=%v", conversationID, state.dispatchID, markErr)
		}
		if _, statusErr := s.conversations.UpdateConversationStatus(conversationID, "failed"); statusErr != nil {
			log.Printf("failed to update conversation status after managed dispatch exit: conversation_id=%q err=%v", conversationID, statusErr)
		}
		return
	}

	if err != nil {
		log.Printf("managed conversation command exited after idle with error: conversation_id=%q dispatch_id=%q err=%v", conversationID, state.dispatchID, err)
	}

	dispatchResult, dispatchErr := s.DispatchConversation(conversationID, "")
	if dispatchErr != nil {
		log.Printf("failed to dispatch next managed conversation batch: conversation_id=%q err=%v", conversationID, dispatchErr)
		return
	}
	if dispatchResult.Started {
		log.Printf("managed conversation batch dispatched: conversation_id=%q", conversationID)
	}
}

func resolveTincanExecPath() (string, error) {
	if executablePath := strings.TrimSpace(os.Getenv("TINCAN_EXECUTABLE")); executablePath != "" {
		if !fileExists(executablePath) {
			return "", fmt.Errorf("TINCAN_EXECUTABLE does not exist: %s", executablePath)
		}
		return executablePath, nil
	}

	if layout, ok := bundledRuntimeLayoutFromExecutable(); ok {
		candidate := filepath.Join(layout.rootDir, "tincan-exec")
		if fileExists(candidate) {
			return candidate, nil
		}
	}

	if layout, ok := bundledRuntimeLayoutFromRoot(
		filepath.Clean(filepath.Join("..", "tincan-swift-app", "BundledRuntime")),
	); ok {
		candidate := filepath.Join(layout.rootDir, "tincan-exec")
		if fileExists(candidate) {
			return candidate, nil
		}
	}

	return "", fmt.Errorf("unable to locate tincan-exec; bundle BundledRuntime with tincan-exec or set TINCAN_EXECUTABLE")
}
