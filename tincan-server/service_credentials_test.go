package main

import (
	"strings"
	"testing"
)

func TestEnvCredentialReaderReturnsTrimmedValue(t *testing.T) {
	reader := envCredentialReader{
		lookupEnv: func(name string) (string, bool) {
			if name != grokAPIKeyEnvVar {
				t.Fatalf("unexpected env lookup %q", name)
			}
			return "  secret-key  ", true
		},
	}

	value, err := reader.APIKey(grokAPIKeyEnvVar)
	if err != nil {
		t.Fatalf("expected lookup to succeed: %v", err)
	}
	if value != "secret-key" {
		t.Fatalf("expected trimmed env value, got %q", value)
	}
}

func TestEnvCredentialReaderReturnsErrorWhenUnset(t *testing.T) {
	reader := envCredentialReader{
		lookupEnv: func(name string) (string, bool) {
			return "", false
		},
	}

	_, err := reader.APIKey(grokAPIKeyEnvVar)
	if err == nil {
		t.Fatal("expected unset env var to fail")
	}
	if !strings.Contains(err.Error(), "not set") {
		t.Fatalf("expected not set error, got %v", err)
	}
}

func TestEnvCredentialReaderReturnsErrorWhenEmpty(t *testing.T) {
	reader := envCredentialReader{
		lookupEnv: func(name string) (string, bool) {
			return "   ", true
		},
	}

	_, err := reader.APIKey(grokAPIKeyEnvVar)
	if err == nil {
		t.Fatal("expected empty env var to fail")
	}
	if !strings.Contains(err.Error(), "empty") {
		t.Fatalf("expected empty error, got %v", err)
	}
}
