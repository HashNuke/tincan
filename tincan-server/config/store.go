package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const (
	configDirectoryName   = "config"
	agentProfilesFileName = "agent_profiles.json"
	agentBackendsFileName = "agent_backends.json"
)

type AgentProfileStore struct {
	mu       sync.RWMutex
	filePath string
	profiles map[string]AgentProfile
}

type AgentBackendStore struct {
	mu       sync.RWMutex
	filePath string
	backends map[string]AgentBackendDefinition
}

func NewAgentProfileStore(dataDir string) (*AgentProfileStore, error) {
	profilesPath := configFilePath(dataDir, agentProfilesFileName)
	if err := ensureConfigFile(dataDir, agentProfilesFileName, []byte("{}\n")); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(profilesPath)
	if err != nil {
		return nil, fmt.Errorf("read agent profiles: %w", err)
	}

	profiles, err := decodeAgentProfiles(data)
	if err != nil {
		return nil, fmt.Errorf("decode agent profiles: %w", err)
	}

	return &AgentProfileStore{
		filePath: profilesPath,
		profiles: profiles,
	}, nil
}

func NewAgentBackendStore(dataDir string) (*AgentBackendStore, error) {
	backendsPath := configFilePath(dataDir, agentBackendsFileName)
	if err := ensureConfigFile(dataDir, agentBackendsFileName, []byte("{}\n")); err != nil {
		return nil, err
	}

	data, err := os.ReadFile(backendsPath)
	if err != nil {
		return nil, fmt.Errorf("read agent backends: %w", err)
	}

	var decoded map[string]AgentBackendDefinition
	if err := json.Unmarshal(data, &decoded); err != nil {
		return nil, fmt.Errorf("decode agent backends: %w", err)
	}
	if decoded == nil {
		decoded = map[string]AgentBackendDefinition{}
	}

	backends := make(map[string]AgentBackendDefinition, len(decoded))
	for name, backend := range decoded {
		if name == "" {
			return nil, fmt.Errorf("agent backend name must not be empty")
		}
		if backend.Type == "" {
			return nil, fmt.Errorf("agent backend %q type must not be empty", name)
		}
		backend.Options = normalizeAgentBackendOptions(backend.Options)
		backends[name] = backend
	}

	return &AgentBackendStore{
		filePath: backendsPath,
		backends: backends,
	}, nil
}

func (s *AgentProfileStore) List() []AgentProfile {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make([]AgentProfile, 0, len(s.profiles))
	for _, profile := range s.profiles {
		result = append(result, profile)
	}
	return result
}

func (s *AgentBackendStore) List() map[string]AgentBackendDefinition {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make(map[string]AgentBackendDefinition, len(s.backends))
	for name, backend := range s.backends {
		result[name] = backend
	}
	return result
}

func (s *AgentProfileStore) Get(name string) (AgentProfile, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	profile, ok := s.profiles[normalizeAgentProfileName(name)]
	return profile, ok
}

func normalizeAgentProfileName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

func (s *AgentBackendStore) Get(name string) (AgentBackendDefinition, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	backend, ok := s.backends[name]
	return backend, ok
}

func (s *AgentProfileStore) Create(profile AgentProfile) (AgentProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	validated, normalizedName, err := validateAgentProfile(profile)
	if err != nil {
		return AgentProfile{}, err
	}
	if _, exists := s.profiles[normalizedName]; exists {
		return AgentProfile{}, fmt.Errorf("agent profile %q already exists", validated.Name)
	}

	nextProfiles := cloneProfilesMap(s.profiles)
	nextProfiles[normalizedName] = validated
	if err := writeAgentProfilesFile(s.filePath, nextProfiles); err != nil {
		return AgentProfile{}, err
	}
	s.profiles = nextProfiles
	return validated, nil
}

func (s *AgentProfileStore) Update(existingName string, profile AgentProfile) (AgentProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	normalizedExistingName := normalizeAgentProfileName(existingName)
	if _, exists := s.profiles[normalizedExistingName]; !exists {
		return AgentProfile{}, fmt.Errorf("agent profile %q not found", existingName)
	}

	validated, normalizedUpdatedName, err := validateAgentProfile(profile)
	if err != nil {
		return AgentProfile{}, err
	}
	if normalizedUpdatedName != normalizedExistingName {
		if _, exists := s.profiles[normalizedUpdatedName]; exists {
			return AgentProfile{}, fmt.Errorf("agent profile %q already exists", validated.Name)
		}
	}

	nextProfiles := cloneProfilesMap(s.profiles)
	delete(nextProfiles, normalizedExistingName)
	nextProfiles[normalizedUpdatedName] = validated
	if err := writeAgentProfilesFile(s.filePath, nextProfiles); err != nil {
		return AgentProfile{}, err
	}
	s.profiles = nextProfiles
	return validated, nil
}

func (s *AgentProfileStore) Delete(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	normalizedName := normalizeAgentProfileName(name)
	if _, exists := s.profiles[normalizedName]; !exists {
		return fmt.Errorf("agent profile %q not found", name)
	}

	nextProfiles := cloneProfilesMap(s.profiles)
	delete(nextProfiles, normalizedName)
	if err := writeAgentProfilesFile(s.filePath, nextProfiles); err != nil {
		return err
	}
	s.profiles = nextProfiles
	return nil
}

func (s *AgentBackendStore) Create(name string, backend AgentBackendDefinition) (AgentBackendDefinition, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	validatedName, validatedBackend, err := validateAgentBackend(name, backend)
	if err != nil {
		return AgentBackendDefinition{}, err
	}
	if _, exists := s.backends[validatedName]; exists {
		return AgentBackendDefinition{}, fmt.Errorf("agent backend %q already exists", validatedName)
	}

	nextBackends := cloneBackendsMap(s.backends)
	nextBackends[validatedName] = validatedBackend
	if err := writeAgentBackendsFile(s.filePath, nextBackends); err != nil {
		return AgentBackendDefinition{}, err
	}
	s.backends = nextBackends
	return validatedBackend, nil
}

func (s *AgentBackendStore) Update(existingName string, backend AgentBackendDefinition) (AgentBackendDefinition, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.backends[existingName]; !exists {
		return AgentBackendDefinition{}, fmt.Errorf("agent backend %q not found", existingName)
	}

	validatedName, validatedBackend, err := validateAgentBackend(existingName, backend)
	if err != nil {
		return AgentBackendDefinition{}, err
	}
	if validatedName != existingName {
		return AgentBackendDefinition{}, fmt.Errorf("agent backend name in body must match request path")
	}

	nextBackends := cloneBackendsMap(s.backends)
	nextBackends[existingName] = validatedBackend
	if err := writeAgentBackendsFile(s.filePath, nextBackends); err != nil {
		return AgentBackendDefinition{}, err
	}
	s.backends = nextBackends
	return validatedBackend, nil
}

func (s *AgentBackendStore) Delete(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.backends[name]; !exists {
		return fmt.Errorf("agent backend %q not found", name)
	}

	nextBackends := cloneBackendsMap(s.backends)
	delete(nextBackends, name)
	if err := writeAgentBackendsFile(s.filePath, nextBackends); err != nil {
		return err
	}
	s.backends = nextBackends
	return nil
}

func validateAgentProfile(profile AgentProfile) (AgentProfile, string, error) {
	profile.Name = strings.TrimSpace(profile.Name)
	profile.WorkingDirectory = strings.TrimSpace(profile.WorkingDirectory)
	profile.AgentBackend = strings.TrimSpace(profile.AgentBackend)
	if profile.Name == "" {
		return AgentProfile{}, "", fmt.Errorf("agent profile name must not be empty")
	}
	if profile.WorkingDirectory == "" {
		return AgentProfile{}, "", fmt.Errorf("agent profile %q working_directory must not be empty", profile.Name)
	}
	if profile.AgentBackend == "" {
		return AgentProfile{}, "", fmt.Errorf("agent profile %q agent_backend must not be empty", profile.Name)
	}
	return profile, normalizeAgentProfileName(profile.Name), nil
}

func validateAgentBackend(name string, backend AgentBackendDefinition) (string, AgentBackendDefinition, error) {
	name = strings.TrimSpace(name)
	backend.Type = strings.TrimSpace(backend.Type)
	backend.Options = normalizeAgentBackendOptions(backend.Options)
	if name == "" {
		return "", AgentBackendDefinition{}, fmt.Errorf("agent backend name must not be empty")
	}
	if backend.Type == "" {
		return "", AgentBackendDefinition{}, fmt.Errorf("agent backend %q type must not be empty", name)
	}
	return name, backend, nil
}

func normalizeAgentBackendOptions(options AgentBackendOptions) AgentBackendOptions {
	options.ConnectionType = strings.TrimSpace(options.ConnectionType)
	options.Command = strings.TrimSpace(options.Command)
	options.ExecutablePath = strings.TrimSpace(options.ExecutablePath)
	options.Model = strings.TrimSpace(options.Model)
	options.ModelVariant = strings.TrimSpace(options.ModelVariant)
	options.Agent = strings.TrimSpace(options.Agent)

	if options.Command == "" {
		options.Command = options.ExecutablePath
	}

	// Persist the new command field and treat executable_path as a read-only legacy alias.
	options.ExecutablePath = ""

	if options.Agent == "" {
		options.Agent = "build"
	}

	return options
}

func decodeAgentProfiles(data []byte) (map[string]AgentProfile, error) {
	var objectDecoded map[string]AgentProfile
	if err := json.Unmarshal(data, &objectDecoded); err == nil {
		if objectDecoded == nil {
			return map[string]AgentProfile{}, nil
		}
		return validateAgentProfilesMap(objectDecoded, false)
	}

	var arrayDecoded []AgentProfile
	if err := json.Unmarshal(data, &arrayDecoded); err != nil {
		return nil, err
	}

	profiles := make(map[string]AgentProfile, len(arrayDecoded))
	for _, profile := range arrayDecoded {
		validated, normalizedName, err := validateAgentProfile(profile)
		if err != nil {
			return nil, err
		}
		if _, exists := profiles[normalizedName]; exists {
			return nil, fmt.Errorf("duplicate agent profile %q", profile.Name)
		}
		profiles[normalizedName] = validated
	}
	return profiles, nil
}

func validateAgentProfilesMap(source map[string]AgentProfile, allowLegacyNameKey bool) (map[string]AgentProfile, error) {
	profiles := make(map[string]AgentProfile, len(source))
	for key, profile := range source {
		validated, normalizedName, err := validateAgentProfile(profile)
		if err != nil {
			return nil, err
		}

		normalizedKey := normalizeAgentProfileName(key)
		if normalizedKey == "" {
			if !allowLegacyNameKey {
				return nil, fmt.Errorf("agent profile key must not be empty")
			}
			normalizedKey = normalizedName
		}

		if _, exists := profiles[normalizedKey]; exists {
			return nil, fmt.Errorf("duplicate agent profile key %q", key)
		}
		profiles[normalizedKey] = validated
	}
	return profiles, nil
}

func writeAgentProfilesFile(filePath string, profiles map[string]AgentProfile) error {
	sortedKeys := make([]string, 0, len(profiles))
	for key := range profiles {
		sortedKeys = append(sortedKeys, key)
	}
	sort.Strings(sortedKeys)

	orderedProfiles := make(map[string]AgentProfile, len(sortedKeys))
	for _, key := range sortedKeys {
		orderedProfiles[key] = profiles[key]
	}
	return writeJSONFile(filePath, orderedProfiles)
}

func writeAgentBackendsFile(filePath string, backends map[string]AgentBackendDefinition) error {
	return writeJSONFile(filePath, backends)
}

func writeJSONFile(filePath string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config file %s: %w", filePath, err)
	}
	data = append(data, '\n')

	tempPath := filePath + ".tmp"
	if err := os.WriteFile(tempPath, data, 0o644); err != nil {
		return fmt.Errorf("write config file %s: %w", tempPath, err)
	}
	if err := os.Rename(tempPath, filePath); err != nil {
		return fmt.Errorf("replace config file %s: %w", filePath, err)
	}
	return nil
}

func cloneProfilesMap(source map[string]AgentProfile) map[string]AgentProfile {
	cloned := make(map[string]AgentProfile, len(source))
	for name, profile := range source {
		cloned[name] = profile
	}
	return cloned
}

func cloneBackendsMap(source map[string]AgentBackendDefinition) map[string]AgentBackendDefinition {
	cloned := make(map[string]AgentBackendDefinition, len(source))
	for name, backend := range source {
		cloned[name] = backend
	}
	return cloned
}

func configDirectoryPath(dataDir string) string {
	return filepath.Join(dataDir, configDirectoryName)
}

func configFilePath(dataDir string, fileName string) string {
	return filepath.Join(configDirectoryPath(dataDir), fileName)
}

func ensureConfigFile(dataDir string, fileName string, defaultContents []byte) error {
	configPath := configFilePath(dataDir, fileName)
	legacyPath := filepath.Join(dataDir, fileName)

	if err := os.MkdirAll(configDirectoryPath(dataDir), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	if _, err := os.Stat(configPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat config file %s: %w", configPath, err)
	}

	if _, err := os.Stat(legacyPath); err == nil {
		if err := os.Rename(legacyPath, configPath); err != nil {
			return fmt.Errorf("migrate config file %s to %s: %w", legacyPath, configPath, err)
		}
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat legacy config file %s: %w", legacyPath, err)
	}

	if err := os.WriteFile(configPath, defaultContents, 0o644); err != nil {
		return fmt.Errorf("create config file %s: %w", configPath, err)
	}
	return nil
}
