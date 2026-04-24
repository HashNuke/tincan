package main

import "testing"

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
