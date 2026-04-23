package main

import (
	"strings"
	"testing"
)

func TestServiceCredentialStoreBootstrapsKnownEnvironmentSecrets(t *testing.T) {
	store := newServiceCredentialStore(func(name string) (string, bool) {
		if name != grokAPIKeyEnvVar {
			t.Fatalf("unexpected env lookup %q", name)
		}
		return "  secret-key  ", true
	})

	value, err := store.APIKey(grokAPIKeyEnvVar)
	if err != nil {
		t.Fatalf("expected bootstrapped env secret to be available: %v", err)
	}
	if value != "secret-key" {
		t.Fatalf("expected trimmed env secret, got %q", value)
	}
}

func TestServiceCredentialStoreIgnoresUnsetEnvironmentSecrets(t *testing.T) {
	store := newServiceCredentialStore(func(name string) (string, bool) {
		return "", false
	})

	_, err := store.APIKey(grokAPIKeyEnvVar)
	if err == nil {
		t.Fatal("expected unset env secret to be unavailable")
	}
	if !strings.Contains(err.Error(), "not set") {
		t.Fatalf("expected not set error, got %v", err)
	}
}

func TestServiceCredentialStoreIgnoresEmptyEnvironmentSecrets(t *testing.T) {
	store := newServiceCredentialStore(func(name string) (string, bool) {
		return "   ", true
	})

	_, err := store.APIKey(grokAPIKeyEnvVar)
	if err == nil {
		t.Fatal("expected empty env secret to be ignored")
	}
	if !strings.Contains(err.Error(), "not set") {
		t.Fatalf("expected not set error, got %v", err)
	}
}

func TestServiceCredentialStoreAppliesPartialSecretUpdatesWithoutReplacingOtherKeys(t *testing.T) {
	store := newServiceCredentialStore(nil)
	alpha := "alpha-secret"
	bravo := "bravo-secret"
	charlie := "charlie-secret"
	if err := store.ApplySecretUpdates(map[string]*string{
		"A": &alpha,
		"B": &bravo,
		"C": &charlie,
	}); err != nil {
		t.Fatalf("initial ApplySecretUpdates failed: %v", err)
	}

	alphaUpdated := "alpha-secret-updated"
	if err := store.ApplySecretUpdates(map[string]*string{
		"A": &alphaUpdated,
	}); err != nil {
		t.Fatalf("partial ApplySecretUpdates failed: %v", err)
	}

	assertCredentialValue(t, store, "A", "alpha-secret-updated")
	assertCredentialValue(t, store, "B", "bravo-secret")
	assertCredentialValue(t, store, "C", "charlie-secret")
}

func TestServiceCredentialStoreRuntimeUpdateOverridesBootstrappedEnvironmentValue(t *testing.T) {
	store := newServiceCredentialStore(func(name string) (string, bool) {
		return "env-secret", true
	})

	value := " runtime-secret "
	if err := store.ApplySecretUpdates(map[string]*string{
		grokAPIKeyEnvVar: &value,
	}); err != nil {
		t.Fatalf("ApplySecretUpdates failed: %v", err)
	}

	assertCredentialValue(t, store, grokAPIKeyEnvVar, "runtime-secret")
}

func TestServiceCredentialStoreClearRemovesBootstrappedEnvironmentValue(t *testing.T) {
	store := newServiceCredentialStore(func(name string) (string, bool) {
		return "env-secret", true
	})

	empty := ""
	if err := store.ApplySecretUpdates(map[string]*string{
		grokAPIKeyEnvVar: &empty,
	}); err != nil {
		t.Fatalf("ApplySecretUpdates failed: %v", err)
	}

	_, err := store.APIKey(grokAPIKeyEnvVar)
	if err == nil {
		t.Fatal("expected cleared runtime credential to be unavailable")
	}
	if !strings.Contains(err.Error(), "not set") {
		t.Fatalf("expected not set error, got %v", err)
	}
}

func assertCredentialValue(t *testing.T, store *serviceCredentialStore, account string, want string) {
	t.Helper()

	got, err := store.APIKey(account)
	if err != nil {
		t.Fatalf("expected credential %s to be available: %v", account, err)
	}
	if got != want {
		t.Fatalf("expected credential %s = %q, got %q", account, want, got)
	}
}
