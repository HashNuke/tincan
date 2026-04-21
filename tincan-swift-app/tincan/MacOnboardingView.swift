#if os(macOS)
import SwiftUI

struct MacOnboardingView: View {
    @ObservedObject var viewModel: MacOnboardingViewModel

    var body: some View {
        Group {
            switch viewModel.step {
            case .preflight:
                preflightView
            case .agents:
                agentSetupView
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 560)
    }

    private var preflightView: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up tincan")
                    .font(.largeTitle.weight(.bold))

                Text("tincan will run its own server on this Mac. First, confirm that OpenCode is installed.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: statusImageName)
                            .font(.title2)
                            .foregroundStyle(statusColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusTitle)
                                .font(.headline)
                            Text(statusMessage)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let path = viewModel.opencodePath {
                        detailRow(label: "Path", value: path)
                    }

                    if !viewModel.availableModels(for: .opencode).isEmpty {
                        detailRow(
                            label: "Models",
                            value: "\(viewModel.availableModels(for: .opencode).count) available"
                        )
                    }

                    if let preflightErrorMessage = viewModel.preflightErrorMessage {
                        Text(preflightErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer()

            HStack {
                Button("Check Again") {
                    viewModel.refreshOpenCodeStatus()
                }
                .disabled(viewModel.isCheckingOpencode)

                Spacer()

                if viewModel.canContinueFromPreflight {
                    Button("Next") {
                        viewModel.continueToAgentSetup()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var agentSetupView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent profiles")
                        .font(.largeTitle.weight(.bold))

                    Text("Atlas is included by default. Add more agents only if you need them.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Back") {
                    viewModel.returnToPreflight()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    atlasCard

                    HStack {
                        Text("Additional agents")
                            .font(.headline)

                        Spacer()

                        Button("Add Agent") {
                            viewModel.addAgent()
                        }
                    }

                    if viewModel.additionalAgents.isEmpty {
                        Text("No extra agents yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
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
                .padding(.vertical, 4)
            }

            if let saveErrorMessage = viewModel.saveErrorMessage {
                Text(saveErrorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("Config will be written to \(AppPaths.generatedConfigDirectory.path)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(viewModel.isSaving ? "Saving..." : "Save Config") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSaveAgents || viewModel.isSaving)
            }
        }
    }

    private var atlasCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Atlas")
                        .font(.headline)
                    Spacer()
                    Text("Included")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                detailRow(label: "Agent backend", value: viewModel.atlasBackend.displayName)
                detailRow(label: "Agent folder", value: viewModel.atlasAgentFolder, truncateMiddle: true)
                detailRow(label: "Model", value: viewModel.atlasModel.isEmpty ? "Waiting for OpenCode" : viewModel.atlasModel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Text("Default agent")
        }
    }

    private func detailRow(label: String, value: String, truncateMiddle: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            Text(value)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(truncateMiddle ? .middle : .tail)
        }
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

    private var statusColor: Color {
        if viewModel.isCheckingOpencode {
            return .secondary
        }
        if viewModel.canContinueFromPreflight {
            return .green
        }
        return .orange
    }

    private var statusTitle: String {
        if viewModel.isCheckingOpencode {
            return "Checking for OpenCode"
        }
        if viewModel.canContinueFromPreflight {
            return "Found OpenCode"
        }
        return "OpenCode not ready"
    }

    private var statusMessage: String {
        if viewModel.isCheckingOpencode {
            return "Looking for `opencode` on PATH and reading the available models."
        }
        if viewModel.canContinueFromPreflight {
            return "OpenCode is installed and will be used for Atlas and any agents you add here."
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
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New agent" : draft.name)
                        .font(.headline)

                    Spacer()

                    Button("Remove", role: .destructive) {
                        onRemove()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.subheadline.weight(.semibold))
                    TextField("Emma", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent backend")
                        .font(.subheadline.weight(.semibold))
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
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        TextField("/Users/akash/code/my-project", text: $draft.agentFolder)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: draft.agentFolder) { _, newValue in
                                onFolderChange(newValue)
                            }

                        Button("Choose") {
                            onChooseFolder()
                        }
                    }
                }

                ModelAutocompleteField(
                    title: "Model",
                    text: $draft.model,
                    suggestions: modelSuggestions,
                    totalOptionCount: allModelOptions.count
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
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
                .font(.subheadline.weight(.semibold))

            TextField("openai/gpt-5.3-codex-spark", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if isFocused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        Button {
                            text = suggestion
                            isFocused = false
                        } label: {
                            Text(suggestion)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)

                        if index < suggestions.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            } else if totalOptionCount > 0 {
                Text("\(totalOptionCount) models available")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
