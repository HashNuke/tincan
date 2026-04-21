#if os(macOS)
import SwiftUI

struct MacOnboardingView: View {
    @ObservedObject var viewModel: MacOnboardingViewModel

    var body: some View {
        TincanCanvas {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    switch viewModel.step {
                    case .preflight:
                        preflightView
                    case .agents:
                        agentSetupView
                    }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .frame(minWidth: 860, minHeight: 680)
    }

    private var preflightView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up tincan")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)

                Text("This Mac becomes the always-on call surface for routing speech into your coding agents.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            TincanSettingsSectionCard(title: "OpenCode preflight") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: statusImageName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(statusTone)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TincanCapsuleTag(text: statusTitle.lowercased(), tone: statusTone)
                                if viewModel.isCheckingOpencode {
                                    TincanCapsuleTag(text: "checking", tone: TincanPalette.panelRaised, filled: false)
                                }
                            }

                            Text(statusMessage)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(TincanPalette.textPrimary)
                        }
                    }

                    if let path = viewModel.opencodePath {
                        detailRow(label: "Path", value: path, truncateMiddle: true)
                    }

                    if !viewModel.availableModels(for: .opencode).isEmpty {
                        detailRow(
                            label: "Models",
                            value: "\(viewModel.availableModels(for: .opencode).count) discovered"
                        )
                    }

                    if let preflightErrorMessage = viewModel.preflightErrorMessage {
                        errorBanner(preflightErrorMessage)
                    }

                    HStack(spacing: 10) {
                        TincanToolbarButton(
                            label: "check again",
                            systemImage: "arrow.clockwise",
                            tone: TincanPalette.panelRaised,
                            action: viewModel.refreshOpenCodeStatus
                        )
                        .disabled(viewModel.isCheckingOpencode)

                        if viewModel.canContinueFromPreflight {
                            TincanToolbarButton(
                                label: "next",
                                systemImage: "arrow.right",
                                tone: TincanTone.mint.accent,
                                foreground: TincanPalette.textOnAccent,
                                action: viewModel.continueToAgentSetup
                            )
                        }
                    }
                }
            }
        }
    }

    private var agentSetupView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent profiles")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(TincanPalette.textPrimary)

                    Text("Atlas ships first. Add extra profiles only if you actually need separate working directories or backends.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(TincanPalette.textSecondary)
                }

                Spacer()

                TincanToolbarButton(
                    label: "back",
                    systemImage: "chevron.left",
                    tone: TincanPalette.panelRaised,
                    action: viewModel.returnToPreflight
                )
            }

            TincanSettingsSectionCard(title: "Default agent") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Atlas")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)

                        Spacer()

                        TincanCapsuleTag(text: "included", tone: TincanTone.mint.accent)
                    }

                    detailRow(label: "Agent backend", value: viewModel.atlasBackend.displayName)
                    detailRow(label: "Agent folder", value: viewModel.atlasAgentFolder, truncateMiddle: true)
                    detailRow(label: "Model", value: viewModel.atlasModel.isEmpty ? "Waiting for OpenCode" : viewModel.atlasModel)
                }
            }

            TincanSettingsSectionCard(title: "Additional agents") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("These become extra server-side profiles after onboarding.")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(TincanPalette.textMuted)

                        Spacer()

                        TincanToolbarButton(
                            label: "add agent",
                            systemImage: "plus",
                            tone: TincanPalette.panelRaised,
                            action: viewModel.addAgent
                        )
                    }

                    if viewModel.additionalAgents.isEmpty {
                        Text("No extra agents yet.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(TincanPalette.textSecondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(viewModel.additionalAgents) { draft in
                            EditableAgentCard(
                                draft: binding(for: draft.id),
                                availableBackends: MacOnboardingViewModel.AgentBackend.allCases,
                                modelSuggestions: viewModel.filteredModelSuggestions(for: draft),
                                allModelOptions: viewModel.availableModels(for: draft.backend),
                                onChooseFolder: {
                                    viewModel.chooseFolder(for: draft.id)
                                },
                                onRemove: {
                                    viewModel.removeAgent(id: draft.id)
                                },
                                onBackendChange: { backend in
                                    viewModel.updateBackend(backend, for: draft.id)
                                },
                                onFolderChange: { folder in
                                    viewModel.updateAgentFolder(folder, for: draft.id)
                                }
                            )
                        }
                    }
                }
            }

            if let saveErrorMessage = viewModel.saveErrorMessage {
                errorBanner(saveErrorMessage)
            }

            HStack {
                Text("Config will be written to \(AppPaths.generatedConfigDirectory.path)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                TincanToolbarButton(
                    label: viewModel.isSaving ? "saving" : "save config",
                    systemImage: "checkmark.circle.fill",
                    tone: TincanTone.mint.accent,
                    foreground: TincanPalette.textOnAccent,
                    action: viewModel.completeOnboarding
                )
                .disabled(!viewModel.canSaveAgents || viewModel.isSaving)
            }
        }
    }

    private func detailRow(label: String, value: String, truncateMiddle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(truncateMiddle ? .middle : .tail)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(TincanTone.coral.accent)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(TincanTone.coral.tint.opacity(0.5))
            )
    }

    private var statusImageName: String {
        if viewModel.isCheckingOpencode {
            return "magnifyingglass.circle"
        }
        if viewModel.canContinueFromPreflight {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private var statusTone: Color {
        if viewModel.isCheckingOpencode {
            return TincanPalette.textSecondary
        }
        if viewModel.canContinueFromPreflight {
            return TincanTone.mint.accent
        }
        return TincanTone.amber.accent
    }

    private var statusTitle: String {
        if viewModel.isCheckingOpencode {
            return "Checking OpenCode"
        }
        if viewModel.canContinueFromPreflight {
            return "OpenCode ready"
        }
        return "OpenCode not ready"
    }

    private var statusMessage: String {
        if viewModel.isCheckingOpencode {
            return "Looking for `opencode` on PATH and reading the available models."
        }
        if viewModel.canContinueFromPreflight {
            return "OpenCode is installed and ready to back Atlas plus any extra agents you add."
        }
        return "Install OpenCode, then run the check again."
    }

    private func binding(for id: UUID) -> Binding<MacOnboardingViewModel.AgentDraft> {
        Binding(
            get: {
                viewModel.additionalAgents.first(where: { $0.id == id }) ??
                MacOnboardingViewModel.AgentDraft(
                    id: id,
                    name: "",
                    backend: .opencode,
                    agentFolder: "",
                    model: ""
                )
            },
            set: { updatedDraft in
                guard let index = viewModel.additionalAgents.firstIndex(where: { $0.id == id }) else {
                    return
                }
                viewModel.additionalAgents[index] = updatedDraft
            }
        )
    }
}

private struct EditableAgentCard: View {
    @Binding var draft: MacOnboardingViewModel.AgentDraft

    let availableBackends: [MacOnboardingViewModel.AgentBackend]
    let modelSuggestions: [String]
    let allModelOptions: [String]
    let onChooseFolder: () -> Void
    let onRemove: () -> Void
    let onBackendChange: (MacOnboardingViewModel.AgentBackend) -> Void
    let onFolderChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New agent" : draft.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)

                Spacer()

                TincanToolbarButton(
                    label: "remove",
                    systemImage: "trash.fill",
                    tone: TincanPalette.callRed,
                    action: onRemove
                )
            }

            MacOnboardingField(label: "Name", placeholder: "Emma", text: $draft.name)

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent backend")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)

                Picker("Agent backend", selection: $draft.backend) {
                    ForEach(availableBackends) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: draft.backend) { _, newValue in
                    onBackendChange(newValue)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent folder")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)

                HStack(spacing: 10) {
                    TextField("/Users/akash/code/my-project", text: $draft.agentFolder)
                        .textFieldStyle(.plain)
                        .foregroundStyle(TincanPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(TincanPalette.panelRaised.opacity(0.82))
                        )
                        .onChange(of: draft.agentFolder) { _, newValue in
                            onFolderChange(newValue)
                        }

                    TincanToolbarButton(
                        label: "choose",
                        systemImage: "folder",
                        tone: TincanPalette.panelRaised,
                        action: onChooseFolder
                    )
                }
            }

            ModelAutocompleteField(
                title: "Model",
                text: $draft.model,
                suggestions: modelSuggestions,
                totalOptionCount: allModelOptions.count
            )
        }
        .padding(16)
        .tincanCard(cornerRadius: 24, raised: true)
    }
}

private struct ModelAutocompleteField: View {
    let title: String
    @Binding var text: String
    let suggestions: [String]
    let totalOptionCount: Int

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)

            TextField("openai/gpt-5.3-codex-spark", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(TincanPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TincanPalette.panelRaised.opacity(0.82))
                )
                .focused($isFocused)

            if isFocused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        Button {
                            text = suggestion
                            isFocused = false
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(TincanPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

                        if index < suggestions.count - 1 {
                            Divider()
                                .overlay(TincanPalette.divider)
                        }
                    }
                }
                .background(TincanPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(TincanPalette.shellBorder, lineWidth: 1)
                )
            } else if totalOptionCount > 0 {
                Text("\(totalOptionCount) models available")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
            }
        }
    }
}

private struct MacOnboardingField: View {
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
#endif
