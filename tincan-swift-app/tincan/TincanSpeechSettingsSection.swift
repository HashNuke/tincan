#if os(macOS)
import SwiftUI

struct TincanSpeechSettingsSection: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechModelsSettingsCard(speechSettings: speechSettings)
            TincanSpeechServicesSettingsCard(speechSettings: speechSettings)
            TincanSpeechSettingsActionsCard(speechSettings: speechSettings)
        }
    }
}

struct TincanSpeechPageContent: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechModelsSettingsCard(speechSettings: speechSettings)
            TincanSpeechSettingsActionsCard(speechSettings: speechSettings)
        }
    }
}

struct TincanServicesPageContent: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechServicesSettingsCard(speechSettings: speechSettings)
            TincanSpeechSettingsActionsCard(speechSettings: speechSettings)
        }
    }
}

private struct TincanSpeechSettingsLocalNote: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        if speechSettings.isRemoteServerSelected {
            TincanSpeechSettingsNote(
                text: "These settings are saved on this Mac. Saving them will restart the bundled server only when you are using Run on this Mac."
            )
        }
    }
}

private struct TincanSpeechModelsSettingsCard: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        TincanSettingsSectionCard(
            title: "Speech services",
            subtitle: "macOS-only. Pick the active STT and TTS providers for the bundled Mac server."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if speechSettings.isLoading {
                    Text("Loading current speech config...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(TincanPalette.textSecondary)
                }

                TincanSpeechModelDropdown(
                    label: TincanSpeechModelTarget.speechToText.label,
                    selectedTitle: speechSettings.selectedModelTitle(for: .speechToText),
                    options: speechSettings.modelOptions(for: .speechToText)
                ) { selectedValue in
                    speechSettings.setModel(selectedValue, for: .speechToText)
                }

                TincanSpeechModelDropdown(
                    label: TincanSpeechModelTarget.textToSpeech.label,
                    selectedTitle: speechSettings.selectedModelTitle(for: .textToSpeech),
                    options: speechSettings.modelOptions(for: .textToSpeech)
                ) { selectedValue in
                    speechSettings.setModel(selectedValue, for: .textToSpeech)
                }

                Text("Dropdowns include the macOS default plus models from services that are currently enabled.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)
            }
        }
    }
}

private struct TincanSpeechServicesSettingsCard: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    @State private var isGrokExpanded = true

    var body: some View {
        TincanSettingsSectionCard(
            title: "Services",
            subtitle: "Toggle providers, manage non-secret endpoints, and store credentials locally in Keychain."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                TincanServiceDisclosureHeader(
                    title: TincanSpeechServiceID.grok.title,
                    isExpanded: isGrokExpanded,
                    isEnabled: speechSettings.grokEnabled,
                    onToggleExpansion: { isGrokExpanded.toggle() },
                    onToggleEnabled: { isEnabled in
                        speechSettings.setServiceEnabled(isEnabled, serviceID: .grok)
                    }
                )

                if isGrokExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        TincanSpeechLabeledField(
                            label: "Base URL",
                            placeholder: speechSettings.grokBaseURLPlaceholder,
                            text: $speechSettings.grokBaseURL
                        )

                        Text("Leave Base URL blank to use the default Grok endpoint.")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(TincanPalette.textMuted)

                        HStack(spacing: 8) {
                            TincanCapsuleTag(
                                text: speechSettings.hasStoredGrokAPIKey ? "key stored" : "no key",
                                tone: speechSettings.hasStoredGrokAPIKey ? TincanTone.mint.accent : TincanTone.coral.accent
                            )

                            if speechSettings.usesGrok {
                                TincanCapsuleTag(text: "grok active", tone: TincanTone.blue.accent, filled: false)
                            }
                        }

                        TincanLabeledSecureField(
                            label: "API key",
                            placeholder: speechSettings.grokAPIKeyPlaceholder,
                            text: $speechSettings.grokAPIKey
                        )

                        HStack(spacing: 10) {
                            TincanToolbarButton(
                                label: speechSettings.isSavingAPIKey ? "saving..." : "save key",
                                systemImage: "key.fill",
                                tone: TincanTone.mint.accent,
                                foreground: TincanPalette.textOnAccent
                            ) {
                                speechSettings.clearStatus()
                                speechSettings.saveGrokAPIKey()
                            }
                            .disabled(speechSettings.isSavingAPIKey || !speechSettings.canSaveGrokAPIKey)

                            if speechSettings.canClearStoredGrokAPIKey {
                                TincanToolbarButton(
                                    label: speechSettings.isSavingAPIKey ? "clearing..." : "clear key",
                                    systemImage: "trash",
                                    tone: TincanTone.coral.accent,
                                    foreground: TincanPalette.textOnAccent
                                ) {
                                    speechSettings.clearStatus()
                                    speechSettings.clearGrokAPIKey()
                                }
                                .disabled(speechSettings.isSavingAPIKey)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(TincanPalette.panelRaised.opacity(0.72))
                    )
                }
            }
        }
    }
}

private struct TincanSpeechSettingsActionsCard: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        TincanSettingsSectionCard(
            title: "Apply changes",
            subtitle: "Save speech model and service changes to the bundled Mac server config."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TincanToolbarButton(
                        label: speechSettings.isSavingConfig ? "saving..." : "save config",
                        systemImage: "square.and.arrow.down",
                        tone: TincanTone.blue.accent,
                        foreground: TincanPalette.textOnAccent
                    ) {
                        speechSettings.clearStatus()
                        Task {
                            await speechSettings.saveConfig()
                        }
                    }
                    .disabled(speechSettings.isSavingConfig)

                    TincanToolbarButton(
                        label: "reload",
                        systemImage: "arrow.clockwise",
                        tone: TincanPalette.panelRaised
                    ) {
                        speechSettings.clearStatus()
                        Task {
                            await speechSettings.load()
                        }
                    }
                    .disabled(speechSettings.isLoading)
                }

                if let statusMessage = speechSettings.statusMessage, !statusMessage.isEmpty {
                    TincanSpeechSettingsBanner(text: statusMessage, tone: TincanTone.mint)
                }

                if let errorMessage = speechSettings.errorMessage, !errorMessage.isEmpty {
                    TincanSpeechSettingsBanner(text: errorMessage, tone: TincanTone.coral)
                }

                if let lastLoadedAt = speechSettings.lastLoadedAt {
                    Text("Last loaded: \(lastLoadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(TincanPalette.textMuted)
                }
            }
        }
    }
}

private struct TincanSpeechModelDropdown: View {
    let label: String
    let selectedTitle: String
    let options: [TincanSpeechModelOption]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            Menu {
                ForEach(options) { option in
                    Button(option.title) {
                        onSelect(option.value)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectedTitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(TincanPalette.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TincanPalette.textMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TincanPalette.panelRaised.opacity(0.82))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TincanServiceDisclosureHeader: View {
    let title: String
    let isExpanded: Bool
    let isEnabled: Bool
    let onToggleExpansion: () -> Void
    let onToggleEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleExpansion) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(TincanPalette.textPrimary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(TincanPalette.textMuted)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggleEnabled($0) }))
                .labelsHidden()
        }
    }
}

private struct TincanSpeechLabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(TincanPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TincanPalette.panelRaised.opacity(0.82))
                )
        }
    }
}

private struct TincanLabeledSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(TincanPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TincanPalette.panelRaised.opacity(0.82))
                )
        }
    }
}

private struct TincanSpeechSettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(TincanPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(TincanTone.amber.tint.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(TincanTone.amber.accent.opacity(0.35), lineWidth: 1)
            )
    }
}

private struct TincanSpeechSettingsBanner: View {
    let text: String
    let tone: TincanTone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(tone == .coral ? TincanPalette.textPrimary : TincanPalette.textOnAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tone == .coral ? tone.tint.opacity(0.82) : tone.accent)
            )
    }
}
#endif
