package main

import (
	"fmt"
	"os"
	"strings"
)

const grokAPIKeyEnvVar = "GROK_API_KEY"

type serviceCredentialReader interface {
	APIKey(account string) (string, error)
}

type envCredentialReader struct {
	lookupEnv func(string) (string, bool)
}

func newServiceCredentialReader() serviceCredentialReader {
	return envCredentialReader{lookupEnv: os.LookupEnv}
}

func (r envCredentialReader) APIKey(account string) (string, error) {
	name := strings.TrimSpace(account)
	if name == "" {
		return "", fmt.Errorf("credential name is empty")
	}

	value, ok := r.lookupEnv(name)
	if !ok {
		return "", fmt.Errorf("environment variable %s is not set", name)
	}

	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", fmt.Errorf("environment variable %s is empty", name)
	}

	return trimmed, nil
}
