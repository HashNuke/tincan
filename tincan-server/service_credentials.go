package main

const (
	keychainServiceName = "com.tincanbot"
	grokAPIKeyAccount   = "GROK_API_KEY"
)

type serviceCredentialReader interface {
	APIKey(account string) (string, error)
}
