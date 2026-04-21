import SwiftUI

#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

struct TincanCallPresentationState {
    let callStateDescription: String
    let isCallActive: Bool
    let isTransitioning: Bool
    let callStartedAt: Date?
    let isMuted: Bool
    let isSpeakerEnabled: Bool
    let inputLevelHistory: [Double]
    let lastServerTranscript: String
    let logLines: [String]
    let speakerIdentity: TincanSpeakerIdentityPresentation?
}

struct TincanSpeakerIdentityPresentation {
    let phase: SpeakerIdentityPhase
    let title: String
    let description: String
    let detail: String
}

struct TincanCallActions {
    let startCall: () -> Void
    let endCall: () -> Void
    let toggleMute: () -> Void
    let toggleSpeaker: () -> Void
    let beginSpeakerIdentification: (() -> Void)?
    let resetSpeakerProfile: (() -> Void)?
}

#if os(iOS)
struct TincanIOSRootView: View {
    @ObservedObject var callSession: CallSessionViewModel
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore

    @State private var isSettingsPresented = false

    var body: some View {
        TincanAppSurface(
            callState: TincanCallPresentationState(
                callStateDescription: callSession.callStateDescription,
                isCallActive: callSession.isCallActive,
                isTransitioning: callSession.isTransitioningCallState,
                callStartedAt: callSession.callStartedAt,
                isMuted: callSession.isMuted,
                isSpeakerEnabled: callSession.isSpeakerEnabled,
                inputLevelHistory: callSession.inputLevelHistory,
                lastServerTranscript: callSession.lastServerTranscript,
                logLines: callSession.logLines,
                speakerIdentity: nil
            ),
            callActions: TincanCallActions(
                startCall: callSession.startCall,
                endCall: callSession.endCall,
                toggleMute: callSession.toggleMute,
                toggleSpeaker: callSession.toggleSpeakerEnabled,
                beginSpeakerIdentification: nil,
                resetSpeakerProfile: nil
            ),
            workspace: workspace,
            serverSettings: serverSettings,
            settingsTitle: "Settings",
            allowSettingsEditing: false,
            isSettingsPresented: $isSettingsPresented
        )
        .task {
            workspace.start()
            await serverSettings.refreshHealth()
        }
    }
}
#endif

#if os(macOS)
struct TincanMacRootView: View {
    @ObservedObject var callSession: MacCallSessionViewModel
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore

    @State private var isSettingsPresented = false

    var body: some View {
        TincanAppSurface(
            callState: TincanCallPresentationState(
                callStateDescription: callSession.callStateDescription,
                isCallActive: callSession.isCallActive,
                isTransitioning: callSession.isTransitioningCallState,
                callStartedAt: callSession.callStartedAt,
                isMuted: callSession.isMuted,
                isSpeakerEnabled: callSession.isSpeakerEnabled,
                inputLevelHistory: callSession.inputLevelHistory,
                lastServerTranscript: callSession.lastServerTranscript,
                logLines: callSession.logLines,
                speakerIdentity: TincanSpeakerIdentityPresentation(
                    phase: callSession.speakerIdentityPhase,
                    title: speakerIdentityTitle(for: callSession.speakerIdentityPhase),
                    description: callSession.identityStatusDescription,
                    detail: callSession.ownerProfileDescription
                )
            ),
            callActions: TincanCallActions(
                startCall: callSession.startCall,
                endCall: callSession.endCall,
                toggleMute: callSession.toggleMute,
                toggleSpeaker: callSession.toggleSpeakerEnabled,
                beginSpeakerIdentification: callSession.beginSpeakerIdentification,
                resetSpeakerProfile: callSession.resetSpeakerProfile
            ),
            workspace: workspace,
            serverSettings: serverSettings,
            settingsTitle: "Settings",
            allowSettingsEditing: true,
            isSettingsPresented: $isSettingsPresented
        )
        .frame(minWidth: 880, minHeight: 680)
        .task {
            workspace.start()
            await serverSettings.refreshHealth()
        }
    }
}
#endif

private struct TincanAppSurface: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
    let settingsTitle: String
    let allowSettingsEditing: Bool
    @Binding var isSettingsPresented: Bool

    private var selectedConversation: TincanConversationSummary? {
        guard let selectedConversationID = workspace.selectedConversationID else { return nil }
        return workspace.conversation(for: selectedConversationID)
    }

    var body: some View {
        TincanCanvas {
            Group {
                if let selectedConversation {
                    TincanTranscriptScreen(
                        conversation: selectedConversation,
                        messages: workspace.messages(for: selectedConversation.id),
                        callState: callState,
                        callActions: callActions,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                workspace.closeConversation()
                            }
                        }
                    )
                    .task(id: selectedConversation.id) {
                        await workspace.refreshConversation(conversationID: selectedConversation.id)
                    }
                } else {
                    TincanHomeScreen(
                        conversations: workspace.conversations,
                        highlightedLiveUpdate: workspace.highlightedLiveUpdate,
                        callState: callState,
                        liveConnectionStatus: workspace.liveConnectionStatus,
                        healthStatus: serverSettings.healthStatus,
                        connectionLabel: serverSettings.shareableConnectionLabel,
                        onOpenSettings: {
                            isSettingsPresented = true
                        },
                        onOpenTranscript: { conversation in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                workspace.openConversation(conversation.id)
                            }
                        },
                        onRefresh: {
                            Task {
                                await workspace.refreshAll()
                            }
                        },
                        callActions: callActions
                    )
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $isSettingsPresented) {
            TincanSettingsScreen(
                workspace: workspace,
                serverSettings: serverSettings,
                callState: callState,
                title: settingsTitle,
                allowEditing: allowSettingsEditing,
                onDismiss: {
                    isSettingsPresented = false
                }
            )
#if os(macOS)
            .frame(minWidth: 760, minHeight: 620)
#endif
        }
    }
}

private struct TincanHomeScreen: View {
    let conversations: [TincanConversationSummary]
    let highlightedLiveUpdate: TincanHighlightedLiveUpdate?
    let callState: TincanCallPresentationState
    let liveConnectionStatus: TincanWorkspaceStore.LiveConnectionStatus
    let healthStatus: ServerConnectionStore.HealthStatus
    let connectionLabel: String
    let onOpenSettings: () -> Void
    let onOpenTranscript: (TincanConversationSummary) -> Void
    let onRefresh: () -> Void
    let callActions: TincanCallActions

    private var featuredConversation: TincanConversationSummary? {
        if let current = conversations.first(where: \.isCurrentCallConversation) {
            return current
        }
        if callState.isCallActive {
            return conversations.first
        }
        return nil
    }

    private var remainingConversations: [TincanConversationSummary] {
        conversations.filter { $0.id != featuredConversation?.id }
    }

    private var statusSummaryText: String {
        "\(connectionLabel) · \(healthSummary(healthStatus)) · \(liveSummary(liveConnectionStatus))"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                TincanHomeHeader(
                    isCallActive: callState.isCallActive,
                    isTransitioning: callState.isTransitioning,
                    onToggleCall: {
                        if callState.isCallActive {
                            callActions.endCall()
                        } else {
                            callActions.startCall()
                        }
                    },
                    onOpenSettings: onOpenSettings
                )

                Text(statusSummaryText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)
                    .padding(.horizontal, 4)

                if callState.isCallActive {
                    TincanCallControlPanel(
                        callState: callState,
                        callActions: callActions
                    )
                }

                if let speakerIdentity = callState.speakerIdentity {
                    TincanIdentityStatusCard(
                        speakerIdentity: speakerIdentity,
                        onIdentify: callActions.beginSpeakerIdentification,
                        onReset: callActions.resetSpeakerProfile
                    )
                }

                if let highlightedLiveUpdate {
                    TincanHighlightedUpdateCard(
                        update: highlightedLiveUpdate,
                        onOpenTranscript: {
                            guard let conversationID = highlightedLiveUpdate.conversationID,
                                  let conversation = conversations.first(where: { $0.id == conversationID }) else {
                                return
                            }
                            onOpenTranscript(conversation)
                        }
                    )
                }

                if let featuredConversation {
                    TincanFeaturedConversationCard(
                        conversation: featuredConversation,
                        onOpenTranscript: {
                            onOpenTranscript(featuredConversation)
                        }
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("conversations")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)

                        Spacer()

                        Button(action: onRefresh) {
                            Text("refresh")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(TincanPalette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(TincanPalette.panel)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if conversations.isEmpty {
                        TincanEmptyConversationsCard(isCallActive: callState.isCallActive)
                    } else {
                        ForEach(remainingConversations) { conversation in
                            TincanConversationRow(
                                conversation: conversation,
                                onOpenTranscript: {
                                    onOpenTranscript(conversation)
                                }
                            )
                        }
                    }
                }

                if !callState.lastServerTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TincanLastTranscriptCard(text: callState.lastServerTranscript)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

private struct TincanHomeHeader: View {
    let isCallActive: Bool
    let isTransitioning: Bool
    let onToggleCall: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 0) {
                Text("tin")
                    .foregroundStyle(TincanPalette.textPrimary)
                Text("can")
                    .foregroundStyle(TincanTone.mint.accent)
            }
            .font(.system(size: 30, weight: .heavy, design: .rounded))

            Spacer()

            HStack(spacing: 10) {
                TincanIconButton(systemImage: "gearshape.fill", tone: TincanPalette.panelRaised, action: onOpenSettings)

                TincanToolbarButton(
                    label: isCallActive ? (isTransitioning ? "ending" : "hang up") : (isTransitioning ? "starting" : "call"),
                    systemImage: isCallActive ? "phone.down.fill" : "phone.fill",
                    tone: isCallActive ? TincanPalette.callRed : TincanTone.mint.accent,
                    foreground: isCallActive ? TincanPalette.textPrimary : TincanPalette.textOnAccent,
                    action: onToggleCall
                )
                .disabled(isTransitioning)
            }
        }
    }
}

private struct TincanCallControlPanel: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(TincanTone.mint.accent)
                        .frame(width: 8, height: 8)
                    Text(callState.callStateDescription.lowercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(TincanTone.mint.accent)
                }

                Spacer()

                if let callStartedAt = callState.callStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedLabel(since: callStartedAt))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(TincanPalette.textSecondary)
                    }
                }
            }

            HStack(spacing: 12) {
                TincanMiniControlButton(
                    systemImage: callState.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    label: "audio",
                    tone: TincanTone.blue.accent,
                    action: callActions.toggleSpeaker
                )

                TincanMiniControlButton(
                    systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: "mute",
                    tone: TincanTone.amber.accent,
                    action: callActions.toggleMute
                )

                TincanMiniControlButton(
                    systemImage: "phone.down.fill",
                    label: "end",
                    tone: TincanPalette.callRed,
                    action: callActions.endCall
                )
            }

            TincanWaveStrip(levels: callState.inputLevelHistory, accent: TincanTone.mint.accent)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TincanPalette.panelMuted.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(TincanTone.mint.accent.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct TincanIdentityStatusCard: View {
    let speakerIdentity: TincanSpeakerIdentityPresentation
    let onIdentify: (() -> Void)?
    let onReset: (() -> Void)?

    private var tone: Color {
        switch speakerIdentity.phase {
        case .ownerVerified:
            return TincanTone.mint.accent
        case .awaitingChallengeResponse:
            return TincanTone.amber.accent
        case .identificationRequired:
            return TincanTone.blue.accent
        case .preparing:
            return TincanPalette.textSecondary
        case .unavailable:
            return TincanTone.coral.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TincanCapsuleTag(text: speakerIdentity.title.lowercased(), tone: tone)
                Spacer()
            }

            Text(speakerIdentity.description)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            Text(speakerIdentity.detail)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TincanPalette.textSecondary)

            HStack(spacing: 10) {
                if let onIdentify {
                    TincanToolbarButton(label: "identify", systemImage: "waveform.badge.mic", tone: TincanPalette.panelRaised, action: onIdentify)
                }
                if let onReset {
                    TincanToolbarButton(label: "reset voice", systemImage: "arrow.counterclockwise", tone: TincanPalette.panelRaised, action: onReset)
                }
            }
        }
        .padding(16)
        .tincanCard(accent: tone, cornerRadius: 24, raised: true)
    }
}

private struct TincanHighlightedUpdateCard: View {
    let update: TincanHighlightedLiveUpdate
    let onOpenTranscript: () -> Void

    var body: some View {
        Button(action: onOpenTranscript) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TincanCapsuleTag(text: update.title, tone: TincanTone.amber.accent)
                    Spacer()
                    Text(relativeTimestampLabel(for: update.timestamp))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TincanPalette.textSecondary)
                }

                Text(update.body)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(TincanTone.amber.tint.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(TincanTone.amber.accent.opacity(0.52), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TincanFeaturedConversationCard: View {
    let conversation: TincanConversationSummary
    let onOpenTranscript: () -> Void

    private var tone: TincanTone {
        tincanTone(for: conversation)
    }

    var body: some View {
        Button(action: onOpenTranscript) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TincanCapsuleTag(text: conversation.handle, tone: tone.accent)
                            TincanCapsuleTag(text: "current", tone: tone.accent.opacity(0.85), filled: false)
                        }

                        Text(summaryText)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 10) {
                        Text(relativeTimestampLabel(for: conversation.updatedAt))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(TincanPalette.textPrimary.opacity(0.82))
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(tone.accent)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tone.tint, TincanPalette.panelRaised.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(tone.accent.opacity(0.5), lineWidth: 1.2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var summaryText: String {
        let trimmedPreview = conversation.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPreview.isEmpty ? "Conversation is active. Open the thread to follow updates." : trimmedPreview
    }
}

private struct TincanConversationRow: View {
    let conversation: TincanConversationSummary
    let onOpenTranscript: () -> Void

    private var tone: TincanTone {
        tincanTone(for: conversation)
    }

    private var borderColor: Color {
        if conversation.hasUnreadTextUpdate {
            return TincanTone.amber.accent
        }
        if conversation.isCurrentCallConversation {
            return tone.accent
        }
        return TincanPalette.shellBorder
    }

    var body: some View {
        Button(action: onOpenTranscript) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tone.tint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(tone.accent.opacity(0.34), lineWidth: 1)
                        )

                    Text(String(conversation.agentProfileName.prefix(2)).uppercased())
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundStyle(tone.accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(conversation.handle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)

                        Spacer()

                        Text(relativeTimestampLabel(for: conversation.updatedAt))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(TincanPalette.textMuted)
                    }

                    Text(previewText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(TincanPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack {
                        Text(metadataText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(TincanPalette.textMuted)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(conversation.hasUnreadTextUpdate ? tone.tint.opacity(0.70) : TincanPalette.panel.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(borderColor, lineWidth: conversation.hasUnreadTextUpdate ? 1.4 : 1)
                    )
                    .shadow(
                        color: conversation.hasUnreadTextUpdate ? tone.accent.opacity(0.18) : .clear,
                        radius: 18,
                        x: 0,
                        y: 10
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var previewText: String {
        let trimmedPreview = conversation.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPreview.isEmpty ? "No server-side update yet." : trimmedPreview
    }

    private var metadataText: String {
        var parts = [shortDirectoryName(conversation.workingDirectory)]
        if conversation.hasPendingUpdate {
            parts.append("pending")
        }
        parts.append(conversation.status)
        return parts.joined(separator: " · ")
    }
}

private struct TincanLastTranscriptCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("last transcript")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(TincanPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

private struct TincanEmptyConversationsCard: View {
    let isCallActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isCallActive ? "No conversations yet" : "No conversations on this server")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            Text(isCallActive
                ? "Stay on the call. Threads will appear here as the router starts or resumes agent conversations."
                : "Start a call or connect to a server that already has threads.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(TincanPalette.textSecondary)
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

private struct TincanTranscriptScreen: View {
    let conversation: TincanConversationSummary
    let messages: [TincanConversationMessage]
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions
    let onBack: () -> Void

    private var tone: TincanTone {
        tincanTone(for: conversation)
    }

    private var timelineMessages: [TincanConversationMessage] {
        messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TincanTranscriptHeader(
                conversation: conversation,
                callState: callState,
                callActions: callActions,
                onBack: onBack
            )

            Divider()
                .overlay(TincanPalette.divider)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if timelineMessages.isEmpty {
                            TincanEmptyTranscriptCard()
                        } else {
                            ForEach(timelineMessages) { message in
                                TincanMessageCard(message: message, accent: tone.accent)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(18)
                }
                .onAppear {
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: timelineMessages.last?.id) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TincanPalette.shell.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(TincanPalette.shellBorder, lineWidth: 1)
                )
        )
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let last = timelineMessages.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct TincanTranscriptHeader: View {
    let conversation: TincanConversationSummary
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions
    let onBack: () -> Void

    private var tone: TincanTone {
        tincanTone(for: conversation)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TincanPalette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(TincanPalette.panel)
                        )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.handle)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(TincanPalette.textPrimary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(callState.isCallActive ? TincanTone.mint.accent : TincanPalette.textMuted)
                            .frame(width: 6, height: 6)
                        Text(callState.isCallActive ? "on call" : "idle")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(callState.isCallActive ? TincanTone.mint.accent : TincanPalette.textMuted)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    TincanMiniHeaderButton(
                        systemImage: callState.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        action: callActions.toggleSpeaker
                    )
                    TincanMiniHeaderButton(
                        systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                        action: callActions.toggleMute
                    )
                    TincanMiniHeaderButton(systemImage: "phone.down.fill", destructive: true, action: callActions.endCall)
                }
            }

            HStack {
                TincanCapsuleTag(text: conversation.agentProfileName, tone: tone.accent)
                Text(shortDirectoryName(conversation.workingDirectory))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(18)
        .background(TincanPalette.panelMuted.opacity(0.97))
    }
}

private struct TincanMessageCard: View {
    let message: TincanConversationMessage
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TincanCapsuleTag(text: message.kind.replacingOccurrences(of: "_", with: " "), tone: accent)
                Spacer()
                Text(timestampLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            if !message.notificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(message.notificationText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            Text(summaryText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)
                .multilineTextAlignment(.leading)

            if detailText != summaryText {
                Text(detailText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(TincanPalette.textSecondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(message.status == "pending" ? accent.opacity(0.14) : TincanPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(message.status == "pending" ? accent.opacity(0.48) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var summaryText: String {
        let trimmed = message.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? detailText : trimmed
    }

    private var detailText: String {
        let trimmed = message.detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No further detail." : trimmed
    }

    private var timestampLabel: String {
        message.updatedAt.formatted(date: .omitted, time: .shortened)
    }
}

private struct TincanEmptyTranscriptCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No updates yet")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            Text("This thread exists, but the server has not recorded any transcript items yet.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(TincanPalette.textSecondary)
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

private struct TincanSettingsScreen: View {
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
    let callState: TincanCallPresentationState
    let title: String
    let allowEditing: Bool
    let onDismiss: () -> Void

    var body: some View {
        TincanCanvas {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Text(title.lowercased())
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)

                        Spacer()

                        TincanToolbarButton(
                            label: "back",
                            systemImage: "chevron.left",
                            tone: TincanPalette.panelRaised,
                            action: onDismiss
                        )
                    }

                    TincanServerSettingsSection(
                        serverSettings: serverSettings,
                        onApplyConnection: {
                            let changed = serverSettings.applyRemoteDraft()
                            if changed {
                                Task {
                                    await workspace.refreshAll()
                                }
                            }
                        },
                        onRefreshHealth: {
                            Task {
                                await serverSettings.refreshHealth()
                            }
                        }
                    )

                    TincanSettingsSectionCard(
                        title: "Agent backends",
                        subtitle: allowEditing ? "Server-backed. Editing can be layered on top of this list next." : "Read-only on iPhone."
                    ) {
                        VStack(spacing: 10) {
                            if workspace.agentBackends.isEmpty {
                                TincanSettingsPlaceholderRow(text: "No backends loaded from the server.")
                            } else {
                                ForEach(workspace.agentBackends) { backend in
                                    TincanBackendRow(backend: backend)
                                }
                            }
                        }
                    }

                    TincanSettingsSectionCard(
                        title: "Agent profiles",
                        subtitle: allowEditing ? "Server-backed profiles for routing conversations." : "Read-only on iPhone."
                    ) {
                        VStack(spacing: 10) {
                            if workspace.agentProfiles.isEmpty {
                                TincanSettingsPlaceholderRow(text: "No profiles loaded from the server.")
                            } else {
                                ForEach(workspace.agentProfiles) { profile in
                                    TincanProfileRow(profile: profile)
                                }
                            }
                        }
                    }

                    TincanSettingsSectionCard(title: "Diagnostics") {
                        VStack(alignment: .leading, spacing: 12) {
                            TincanSettingsValueRow(label: "Call", value: callState.callStateDescription)
                            TincanSettingsValueRow(label: "Live", value: liveSummary(workspace.liveConnectionStatus))
                            TincanSettingsValueRow(label: "Health", value: healthSummary(serverSettings.healthStatus))

                            if let lastRefreshAt = workspace.lastRefreshAt {
                                TincanSettingsValueRow(
                                    label: "Last sync",
                                    value: lastRefreshAt.formatted(date: .omitted, time: .shortened)
                                )
                            }

                            if let speakerIdentity = callState.speakerIdentity {
                                TincanSettingsValueRow(label: "Speaker", value: speakerIdentity.description)
                            }

                            if let lastSyncError = workspace.lastSyncError, !lastSyncError.isEmpty {
                                Text(lastSyncError)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(TincanTone.coral.accent)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(TincanTone.coral.tint.opacity(0.52))
                                    )
                            }

                            if !callState.lastServerTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Last transcript")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(TincanPalette.textMuted)
                                    Text(callState.lastServerTranscript)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(TincanPalette.textSecondary)
                                }
                            }

                            if !callState.logLines.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Recent activity")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(TincanPalette.textMuted)

                                    ForEach(Array(callState.logLines.prefix(6).enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(TincanPalette.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 940)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }
}

private struct TincanServerSettingsSection: View {
    @ObservedObject var serverSettings: ServerConnectionStore
    let onApplyConnection: () -> Void
    let onRefreshHealth: () -> Void

    var body: some View {
        TincanSettingsSectionCard(title: "Server") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
#if os(macOS)
                    TincanServerModeChip(
                        label: ServerConnectionStore.ConnectionMode.localMac.title,
                        isSelected: serverSettings.connectionMode == .localMac
                    ) {
                        serverSettings.setConnectionMode(.localMac)
                        onRefreshHealth()
                    }
#endif
                    TincanServerModeChip(
                        label: ServerConnectionStore.ConnectionMode.remote.title,
                        isSelected: serverSettings.connectionMode == .remote
                    ) {
                        serverSettings.setConnectionMode(.remote)
                        onRefreshHealth()
                    }
                }

                HStack(alignment: .top, spacing: 16) {
#if os(macOS)
                    if serverSettings.connectionMode == .localMac {
                        TincanQRCodeCard(payload: serverSettings.qrPayload)
                    }
#endif

                    VStack(alignment: .leading, spacing: 10) {
                        TincanSettingsValueRow(label: "Current", value: serverSettings.shareableConnectionLabel)
                        TincanSettingsValueRow(label: "Health", value: healthSummary(serverSettings.healthStatus))

                        if serverSettings.connectionMode == .remote {
                            VStack(alignment: .leading, spacing: 10) {
                                TincanLabeledField(label: "Host", text: $serverSettings.draftHost)
                                TincanLabeledField(label: "Port", text: $serverSettings.draftPort)

                                HStack(spacing: 10) {
                                    TincanToolbarButton(
                                        label: "apply",
                                        systemImage: "arrow.clockwise",
                                        tone: TincanTone.mint.accent,
                                        foreground: TincanPalette.textOnAccent,
                                        action: onApplyConnection
                                    )
                                    TincanToolbarButton(label: "check", systemImage: "bolt.horizontal.fill", tone: TincanPalette.panelRaised, action: onRefreshHealth)
                                }
                            }
                        } else {
                            Text("The Mac app assumes the server is reachable on loopback and shares `\(serverSettings.shareableConnectionLabel)` for phones.")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(TincanPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

private struct TincanBackendRow: View {
    let backend: TincanAgentBackend

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(backend.id)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)
                Text("\(backend.type) · \(backend.options.model)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(backend.options.connectionType.isEmpty ? "server" : backend.options.connectionType)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanTone.blue.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TincanPalette.panelRaised.opacity(0.72))
        )
    }
}

private struct TincanProfileRow: View {
    let profile: TincanAgentProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TincanTone.mint.tint)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(profile.name.prefix(2)).uppercased())
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(TincanTone.mint.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)
                Text(shortDirectoryName(profile.workingDirectory))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(profile.agentBackend)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanTone.blue.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TincanPalette.panelRaised.opacity(0.72))
        )
    }
}

private struct TincanSettingsPlaceholderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(TincanPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(TincanPalette.panelRaised.opacity(0.72))
            )
    }
}

private struct TincanSettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

private struct TincanLabeledField: View {
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

#if os(macOS)
private struct TincanQRCodeCard: View {
    let payload: String

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image = makeQRCode(payload: payload) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Text("QR unavailable")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(TincanPalette.textMuted)
                        )
                }
            }
            .frame(width: 128, height: 128)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
            )

            Text("scan")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TincanPalette.textMuted)
        }
    }

    private func makeQRCode(payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }

        let context = CIContext()
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: outputImage.extent.width, height: outputImage.extent.height))
    }
}
#endif

private func elapsedLabel(since startDate: Date) -> String {
    let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
    let hours = elapsed / 3600
    let minutes = (elapsed % 3600) / 60
    let seconds = elapsed % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

private func healthSummary(_ status: ServerConnectionStore.HealthStatus) -> String {
    switch status {
    case .idle:
        return "idle"
    case .checking:
        return "checking"
    case .connected(let agentProfileCount, _):
        return "ok · \(agentProfileCount) profiles"
    case .unreachable(let message, _):
        return "offline · \(message)"
    }
}

private func liveSummary(_ status: TincanWorkspaceStore.LiveConnectionStatus) -> String {
    switch status {
    case .idle:
        return "idle"
    case .connecting:
        return "connecting"
    case .connected:
        return "connected"
    case .disconnected(let message):
        return "disconnected · \(message)"
    }
}

private func speakerIdentityTitle(for phase: SpeakerIdentityPhase) -> String {
    switch phase {
    case .preparing:
        return "Preparing"
    case .identificationRequired:
        return "Identify Speaker"
    case .awaitingChallengeResponse:
        return "Waiting"
    case .ownerVerified:
        return "Owner Verified"
    case .unavailable:
        return "Unavailable"
    }
}
