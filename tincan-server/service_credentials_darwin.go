//go:build darwin

package main

import (
	"errors"
	"strings"

	keychain "github.com/keybase/go-keychain"
)

type keychainCredentialReader struct{}

func newServiceCredentialReader() serviceCredentialReader {
	return keychainCredentialReader{}
}

func (keychainCredentialReader) APIKey(account string) (string, error) {
	query := keychain.NewItem()
	query.SetSecClass(keychain.SecClassGenericPassword)
	query.SetService(keychainServiceName)
	query.SetAccount(account)
	query.SetMatchLimit(keychain.MatchLimitOne)
	query.SetReturnData(true)

	results, err := keychain.QueryItem(query)
	if err != nil {
		return "", err
	}
	if len(results) != 1 {
		return "", keychain.ErrorItemNotFound
	}

	value := strings.TrimSpace(string(results[0].Data))
	if value == "" {
		return "", errors.New("keychain item is empty")
	}
	return value, nil
}
