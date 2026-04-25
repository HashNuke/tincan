package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestNormalizeTailscaleHostname(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{name: "curly apostrophe", in: "Akash’s MacBook air", want: "tincan-akashs-macbook-air"},
		{name: "punctuation runs", in: " Akash!!!Mac---Studio ", want: "tincan-akash-mac-studio"},
		{name: "empty", in: " '’ --- ", want: "tincan-mac"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := normalizeTailscaleHostname(tt.in); got != tt.want {
				t.Fatalf("normalizeTailscaleHostname(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestSelectTailscaleNodeURLSelectsTSNetDomain(t *testing.T) {
	got, err := selectTailscaleNodeURL([]string{"example.com", " tincan-host.tail.ts.net "})
	if err != nil {
		t.Fatalf("selectTailscaleNodeURL returned error: %v", err)
	}
	if got != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected ts.net URL, got %q", got)
	}
}

func TestSelectTailscaleNodeURLStripsTrailingDot(t *testing.T) {
	got, err := selectTailscaleNodeURL([]string{"tincan-host.tail.ts.net."})
	if err != nil {
		t.Fatalf("selectTailscaleNodeURL returned error: %v", err)
	}
	if got != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected trailing dot to be stripped, got %q", got)
	}
}

func TestSelectTailscaleNodeURLIgnoresNonTSNetDomains(t *testing.T) {
	got, err := selectTailscaleNodeURL([]string{"example.com"}, []string{"api.internal"}, []string{"foo.ts.net"})
	if err != nil {
		t.Fatalf("selectTailscaleNodeURL returned error: %v", err)
	}
	if got != "https://foo.ts.net" {
		t.Fatalf("expected foo.ts.net URL, got %q", got)
	}
}

func TestSelectTailscaleNodeURLErrorsWithoutTSNetDomain(t *testing.T) {
	if got, err := selectTailscaleNodeURL([]string{"example.com", "api.internal"}); err == nil {
		t.Fatalf("expected error without ts.net domain, got %q", got)
	}
}

func TestRuntimeTailscaleNodeURLWaitsForTSNetDomain(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	provider := &runtimeTailscaleDomainProviderStub{
		groups: [][]string{
			{"example.com"},
			{"example.com", "tincan-host.tail.ts.net"},
		},
	}

	got, err := runtimeTailscaleNodeURL(ctx, provider)
	if err != nil {
		t.Fatalf("runtimeTailscaleNodeURL returned error: %v", err)
	}
	if got != "https://tincan-host.tail.ts.net" {
		t.Fatalf("expected delayed ts.net URL, got %q", got)
	}
}

func TestRuntimeTailscaleNodeURLReturnsContextErrorWhenDomainNeverArrives(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()

	provider := &runtimeTailscaleDomainProviderStub{
		groups: [][]string{
			{"example.com"},
		},
	}

	_, err := runtimeTailscaleNodeURL(ctx, provider)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected context deadline exceeded, got %v", err)
	}
}

type runtimeTailscaleDomainProviderStub struct {
	groups [][]string
	index  int
}

func (s *runtimeTailscaleDomainProviderStub) CertDomains() []string {
	if len(s.groups) == 0 {
		return nil
	}
	if s.index >= len(s.groups) {
		return s.groups[len(s.groups)-1]
	}

	current := s.groups[s.index]
	s.index++
	return current
}
