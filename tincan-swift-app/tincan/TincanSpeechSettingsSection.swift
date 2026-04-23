#if os(macOS)
import SwiftUI

struct TincanSpeechSettingsSection: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechModelsSettingsCard(speechSettings: speechSettings)
            TincanSpeechServicesSettingsCard(speechSettings: speechSettings)
        }
    }
}

struct TincanSpeechPageContent: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    var showsPageCardTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechModelsSettingsCard(
                speechSettings: speechSettings,
                showsPageCardTitle: showsPageCardTitle
            )
        }
    }
}

struct TincanServicesPageContent: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    var showsPageCardTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TincanSpeechSettingsLocalNote(speechSettings: speechSettings)
            TincanSpeechServicesSettingsCard(
                speechSettings: speechSettings,
                showsPageCardTitle: showsPageCardTitle
            )
        }
    }
}

private struct TincanSpeechSettingsLocalNote: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        if speechSettings.isRemoteServerSelected {
            Text("These settings are saved on this Mac. Saving them will restart the bundled server only when you are using Run on this Mac.")
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TincanSpeechModelsSettingsCard: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    var showsPageCardTitle: Bool = true

    var body: some View {
        TincanSettingsSection(
            title: showsPageCardTitle ? "Speech services" : nil,
            subtitle: "Pick STT and TTS models. Each option includes its dependency note."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if speechSettings.isLoading {
                    Text("Loading current speech config...")
                        .font(TincanSettingsTypography.body)
                        .foregroundStyle(TincanPalette.textSecondary)
                }

                TincanSpeechModelDropdown(
                    label: TincanSpeechModelTarget.speechToText.label,
                    selectedOption: speechSettings.selectedModelOption(for: .speechToText),
                    options: speechSettings.modelOptions(for: .speechToText)
                ) { selectedValue in
                    speechSettings.setModel(selectedValue, for: .speechToText)
                }

                TincanSpeechModelDropdown(
                    label: TincanSpeechModelTarget.textToSpeech.label,
                    selectedOption: speechSettings.selectedModelOption(for: .textToSpeech),
                    options: speechSettings.modelOptions(for: .textToSpeech)
                ) { selectedValue in
                    speechSettings.setModel(selectedValue, for: .textToSpeech)
                }
            }
        }
    }
}

private struct TincanSpeechServicesSettingsCard: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    var showsPageCardTitle: Bool = true
    @State private var isGrokExpanded = true

    var body: some View {
        TincanSettingsSection(
            title: showsPageCardTitle ? "Services" : nil,
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
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        TincanSpeechLabeledField(
                            label: "Base URL",
                            placeholder: speechSettings.grokBaseURLPlaceholder,
                            text: $speechSettings.grokBaseURL
                        )

                        Text("Leave Base URL blank to use the default Grok endpoint.")
                            .font(TincanSettingsTypography.body)
                            .foregroundStyle(TincanPalette.textSecondary)

                        TincanGrokAPIKeyField(speechSettings: speechSettings)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }
}

struct TincanSpeechSettingsBottomBar: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore

    var body: some View {
        HStack(spacing: 16) {
            if let message = messageText {
                Text(message)
                    .font(TincanSettingsTypography.body)
                    .foregroundStyle(messageColor)
                    .lineLimit(2)
            } else {
                Spacer(minLength: 0)
            }

            Spacer()

            Button("Reset") {
                speechSettings.clearStatus()
                Task {
                    await speechSettings.load()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!speechSettings.canReset)

            Button(speechSettings.isSavingConfig ? "Saving..." : "Save") {
                speechSettings.clearStatus()
                Task {
                    await speechSettings.saveConfig()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!speechSettings.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(TincanPalette.panel.opacity(0.96))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(TincanPalette.divider)
                        .frame(height: 1)
                }
        )
    }

    private var messageText: String? {
        if let errorMessage = speechSettings.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let statusMessage = speechSettings.statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return nil
    }

    private var messageColor: Color {
        if let errorMessage = speechSettings.errorMessage, !errorMessage.isEmpty {
            return TincanTone.coral.accent
        }
        return TincanPalette.textSecondary
    }
}

private struct TincanSpeechModelDropdown: View {
    let label: String
    let selectedOption: TincanSpeechModelOption
    let options: [TincanSpeechModelOption]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(TincanSettingsTypography.emphasis)
                .foregroundStyle(TincanPalette.textSecondary)

            Menu {
                ForEach(options) { option in
                    Button {
                        onSelect(option.value)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.note)
                                .font(TincanSettingsTypography.caption)
                                .foregroundStyle(TincanPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(selectedOption.title)
                            .font(TincanSettingsTypography.body)
                            .foregroundStyle(TincanPalette.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TincanPalette.textSecondary)
                    }

                    if !selectedOption.note.isEmpty {
                        Text(selectedOption.note)
                            .font(TincanSettingsTypography.caption)
                            .foregroundStyle(TincanPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                        .font(TincanSettingsTypography.emphasis)
                        .foregroundStyle(TincanPalette.textPrimary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TincanPalette.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggleEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
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
                .font(TincanSettingsTypography.emphasis)
                .foregroundStyle(TincanPalette.textSecondary)

            TextField(placeholder, text: $text)
                .font(TincanSettingsTypography.body)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct TincanGrokAPIKeyField: View {
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    @FocusState private var isFocused: Bool

    private var showsStoredMask: Bool {
        speechSettings.showsMaskedStoredGrokAPIKey && !isFocused
    }

    private var showsStoredKeyIndicator: Bool {
        speechSettings.showsStoredGrokAPIKeyIndicator && !isFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API key")
                    .font(TincanSettingsTypography.emphasis)
                    .foregroundStyle(TincanPalette.textSecondary)

                Spacer()

                if speechSettings.hasStoredGrokAPIKey {
                    Button("Clear") {
                        isFocused = false
                        speechSettings.updateGrokAPIKey("")
                    }
                    .buttonStyle(.plain)
                    .font(TincanSettingsTypography.body)
                    .foregroundStyle(TincanTone.coral.accent)
                }
            }

            ZStack(alignment: .leading) {
                SecureField(
                    "",
                    text: Binding(
                        get: { speechSettings.hasEditedGrokAPIKey ? speechSettings.grokAPIKey : "" },
                        set: { speechSettings.updateGrokAPIKey($0) }
                    )
                )
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textPrimary)
                .padding(.leading, 12)
                .padding(.trailing, 36)
                .padding(.vertical, 10)

                if showsStoredMask {
                    Text(speechSettings.maskedStoredGrokAPIKey)
                        .font(TincanSettingsTypography.body)
                        .foregroundStyle(TincanPalette.textPrimary)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }

                if showsStoredKeyIndicator {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.green)
                            .padding(.trailing, 12)
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TincanPalette.panelRaised.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(TincanPalette.divider, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isFocused = true
            }
        }
    }
}
#endif
