//go:build !darwin

package main

import "fmt"

type unsupportedCredentialReader struct{}

func newServiceCredentialReader() serviceCredentialReader {
	return unsupportedCredentialReader{}
}

func (unsupportedCredentialReader) APIKey(account string) (string, error) {
	return "", fmt.Errorf("keychain credentials are only supported on macOS")
}
