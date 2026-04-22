package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strings"

	tincanconfig "tincan-server/config"
)

type grokSpeechClient struct {
	httpClient       *http.Client
	credentialReader serviceCredentialReader
	config           tincanconfig.GrokServiceConfig
	sttSelection     tincanconfig.SpeechModelSelection
	ttsSelection     tincanconfig.SpeechModelSelection
}

type grokTTSRequest struct {
	Text         string                             `json:"text"`
	VoiceID      string                             `json:"voice_id"`
	Language     string                             `json:"language"`
	OutputFormat tincanconfig.GrokAudioOutputFormat `json:"output_format"`
}

type grokSTTResponse struct {
	Text string `json:"text"`
}

func newGrokSpeechClient(
	services tincanconfig.AppServicesConfig,
	credentialReader serviceCredentialReader,
	sttSelection tincanconfig.SpeechModelSelection,
	ttsSelection tincanconfig.SpeechModelSelection,
) *grokSpeechClient {
	return &grokSpeechClient{
		httpClient:       http.DefaultClient,
		credentialReader: credentialReader,
		config:           tincanconfig.ResolveGrokServiceConfig(services),
		sttSelection:     sttSelection,
		ttsSelection:     ttsSelection,
	}
}

func (c *grokSpeechClient) synthesize(text string) ([]byte, error) {
	if strings.TrimSpace(c.ttsSelection.Model) != "grok-tts-v1" {
		return nil, fmt.Errorf("unsupported Grok TTS model %q", c.ttsSelection.Canonical())
	}

	apiKey, err := c.credentialReader.APIKey(grokAPIKeyAccount)
	if err != nil {
		return nil, fmt.Errorf("lookup GROK_API_KEY: %w", err)
	}

	requestBody, err := json.Marshal(grokTTSRequest{
		Text:         text,
		VoiceID:      c.config.TTS.VoiceID,
		Language:     c.config.TTS.Language,
		OutputFormat: c.config.TTS.OutputFormat,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal grok tts request: %w", err)
	}

	response, err := c.doAuthorizedRequest(
		http.MethodPost,
		strings.TrimRight(c.config.BaseURL, "/")+"/tts",
		"application/json",
		bytes.NewReader(requestBody),
		apiKey,
	)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("grok tts failed with status %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}

	audioData, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("read grok tts response: %w", err)
	}
	return audioData, nil
}

func (c *grokSpeechClient) transcribe(audioData []byte, contentType string) (string, error) {
	if strings.TrimSpace(c.sttSelection.Model) != "grok-stt-v1" {
		return "", fmt.Errorf("unsupported Grok STT model %q", c.sttSelection.Canonical())
	}

	apiKey, err := c.credentialReader.APIKey(grokAPIKeyAccount)
	if err != nil {
		return "", fmt.Errorf("lookup GROK_API_KEY: %w", err)
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)

	partHeader := make(textproto.MIMEHeader)
	normalizedContentType := normalizedAudioContentType(contentType)
	partHeader.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="utterance.%s"`, audioFileExtension(normalizedContentType)))
	partHeader.Set("Content-Type", firstNonEmpty(normalizedContentType, "application/octet-stream"))
	filePart, err := writer.CreatePart(partHeader)
	if err != nil {
		return "", fmt.Errorf("create multipart file part: %w", err)
	}
	if _, err := filePart.Write(audioData); err != nil {
		return "", fmt.Errorf("write multipart file part: %w", err)
	}
	if language := strings.TrimSpace(c.config.STT.Language); language != "" {
		if err := writer.WriteField("language", language); err != nil {
			return "", fmt.Errorf("write language field: %w", err)
		}
	}
	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("close multipart body: %w", err)
	}

	response, err := c.doAuthorizedRequest(
		http.MethodPost,
		strings.TrimRight(c.config.BaseURL, "/")+"/stt",
		writer.FormDataContentType(),
		bytes.NewReader(body.Bytes()),
		apiKey,
	)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return "", fmt.Errorf("grok stt failed with status %d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}

	var decoded grokSTTResponse
	if err := json.NewDecoder(response.Body).Decode(&decoded); err != nil {
		return "", fmt.Errorf("decode grok stt response: %w", err)
	}
	return decoded.Text, nil
}

func (c *grokSpeechClient) doAuthorizedRequest(method string, url string, contentType string, body io.Reader, apiKey string) (*http.Response, error) {
	request, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	return c.httpClient.Do(request)
}

func audioFileExtension(contentType string) string {
	switch normalizedAudioContentType(contentType) {
	case "audio/wav", "audio/x-wav", "audio/wave":
		return "wav"
	case "audio/ogg":
		return "ogg"
	case "audio/webm":
		return "webm"
	case "audio/mp4", "audio/m4a":
		return "m4a"
	case "audio/mpeg", "audio/mp3":
		return "mp3"
	default:
		return "bin"
	}
}

func normalizedAudioContentType(contentType string) string {
	trimmed := strings.TrimSpace(strings.ToLower(contentType))
	if trimmed == "" {
		return ""
	}
	mediaType, _, ok := strings.Cut(trimmed, ";")
	if ok {
		return strings.TrimSpace(mediaType)
	}
	return trimmed
}
