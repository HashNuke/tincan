#if os(macOS)
import SwiftUI

private struct SpeechModelPreset: Identifiable {
    let id: String
    let title: String
    let value: String
}

struct TincanSpeechSettingsSection: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    private let sttPresets = [
        SpeechModelPreset(
            id: "macos-parakeet",
            title: "Parakeet (macOS)",
            value: TincanSpeechSettingsStore.defaultSTTModel
        ),
        SpeechModelPreset(
            id: "grok-stt-v1",
            title: "Grok STT v1",
            value: TincanSpeechSettingsStore.grokSTTModel
        ),
    ]

    private let ttsPresets = [
        SpeechModelPreset(
            id: "macos-kitten",
            title: "Kitten (macOS)",
            value: TincanSpeechSettingsStore.defaultTTSModel
        ),
        SpeechModelPreset(
            id: "grok-tts-v1",
            title: "Grok TTS v1",
            value: TincanSpeechSettingsStore.grokTTSModel
        ),
    ]

    var body: some View {
        TincanSettingsSectionCard(
            title: "Speech services",
            subtitle: "macOS-only. Keep `stt_model` and `tts_model` explicit, and store `GROK_API_KEY` locally in Keychain."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if speechSettings.isRemoteServerSelected {
                    TincanSpeechSettingsNote(
                        text: "You are connected to a remote server. The API key you save here stays on this Mac and only helps when the server runs locally on this Mac."
                    )
                }

                if speechSettings.isLoading {
                    Text("Loading current speech config...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(TincanPalette.textSecondary)
                }

                TincanSpeechModelEditor(
                    label: "stt_model",
                    note: "Use `macos/<folder-name>` for local models, or `provider/model` for remote providers.",
                    text: $speechSettings.sttModel,
                    presets: sttPresets
                )

                TincanSpeechModelEditor(
                    label: "tts_model",
                    note: "Use `macos/<folder-name>` for local models, or `provider/model` for remote providers.",
                    text: $speechSettings.ttsModel,
                    presets: ttsPresets
                )

                VStack(alignment: .leading, spacing: 10) {
                    TincanSpeechLabeledField(label: "services.grok.base_url", text: $speechSettings.grokBaseURL)

                    Text("Leave the Grok base URL at `\(TincanSpeechSettingsStore.defaultGrokBaseURL)` unless you need a proxy or alternate gateway.")
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

                    TincanLabeledSecureField(label: "GROK_API_KEY", text: $speechSettings.grokAPIKey)
                }

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
                        label: speechSettings.isSavingAPIKey ? "saving..." : "save key",
                        systemImage: "key.fill",
                        tone: TincanTone.mint.accent,
                        foreground: TincanPalette.textOnAccent
                    ) {
                        speechSettings.clearStatus()
                        speechSettings.saveGrokAPIKey()
                    }
                    .disabled(speechSettings.isSavingAPIKey)

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

private struct TincanSpeechModelEditor: View {
    let label: String
    let note: String
    @Binding var text: String
    let presets: [SpeechModelPreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TincanSpeechLabeledField(label: label, text: $text)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        TincanServerModeChip(
                            label: preset.title,
                            isSelected: text.trimmingCharacters(in: .whitespacesAndNewlines) == preset.value
                        ) {
                            text = preset.value
                        }
                    }
                }
            }

            Text(note)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)
        }
    }
}

private struct TincanSpeechLabeledField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            TextField("", text: $text)
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
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            SecureField("", text: $text)
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
