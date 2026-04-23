package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
)

const grokAPIKeyEnvVar = "GROK_API_KEY"

var knownServiceCredentialAccounts = []string{
	grokAPIKeyEnvVar,
}

type serviceCredentialReader interface {
	APIKey(account string) (string, error)
}

type serviceCredentialStore struct {
	mu            sync.RWMutex
	runtimeValues map[string]string
}

func newServiceCredentialReader() *serviceCredentialStore {
	return newServiceCredentialStore(os.LookupEnv)
}

func newServiceCredentialStore(lookupEnv func(string) (string, bool)) *serviceCredentialStore {
	store := &serviceCredentialStore{
		runtimeValues: make(map[string]string),
	}

	if lookupEnv == nil {
		return store
	}

	for _, account := range knownServiceCredentialAccounts {
		name, err := normalizeCredentialAccount(account)
		if err != nil {
			continue
		}
		value, ok := lookupEnv(name)
		if !ok {
			continue
		}
		normalizedValue, err := normalizeCredentialValue("environment variable", name, value)
		if err != nil {
			continue
		}
		store.runtimeValues[name] = normalizedValue
	}

	return store
}

func (s *serviceCredentialStore) APIKey(account string) (string, error) {
	name, err := normalizeCredentialAccount(account)
	if err != nil {
		return "", err
	}

	s.mu.RLock()
	value, ok := s.runtimeValues[name]
	s.mu.RUnlock()
	if !ok {
		return "", credentialNotSetError("runtime credential", name)
	}
	return value, nil
}

func (s *serviceCredentialStore) ApplySecretUpdates(updates map[string]*string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for account, value := range updates {
		name, err := normalizeCredentialAccount(account)
		if err != nil {
			return err
		}

		if value == nil {
			delete(s.runtimeValues, name)
			continue
		}

		normalizedValue, err := normalizeCredentialValue("runtime credential", name, *value)
		if err != nil {
			delete(s.runtimeValues, name)
			continue
		}

		s.runtimeValues[name] = normalizedValue
	}

	return nil
}

func normalizeCredentialAccount(account string) (string, error) {
	name := strings.TrimSpace(account)
	if name == "" {
		return "", fmt.Errorf("credential name is empty")
	}
	return name, nil
}

func normalizeCredentialValue(source string, account string, value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", fmt.Errorf("%s %s is empty", source, account)
	}
	return trimmed, nil
}

func credentialNotSetError(source string, account string) error {
	return fmt.Errorf("%s %s is not set", source, account)
}
