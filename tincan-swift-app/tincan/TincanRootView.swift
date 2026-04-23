import SwiftUI

#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

enum TincanCallTransitionPhase {
    case none
    case starting
    case ending
}

struct TincanCallPresentationState {
    let callStateDescription: String
    let isCallActive: Bool
    let isTransitioning: Bool
    let transitionPhase: TincanCallTransitionPhase
    let callStartedAt: Date?
    let isMuted: Bool
    let isSpeakerEnabled: Bool
    let inputLevelHistory: [Double]
    let lastLocalTranscript: String
    let lastServerTranscript: String
    let recentTranscripts: [TincanTranscriptDisplayItem]
    let logLines: [String]
    let speakerIdentity: TincanSpeakerIdentityPresentation?

    var isStartingTransition: Bool {
        transitionPhase == .starting
    }

    var isEndingTransition: Bool {
        transitionPhase == .ending
    }
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

private enum TincanScrollAnchor {
    static let homeTop = "tincan-home-top"
    static let transcriptTop = "tincan-transcript-top"
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
                transitionPhase: callSession.transitionPhase,
                callStartedAt: callSession.callStartedAt,
                isMuted: callSession.isMuted,
                isSpeakerEnabled: callSession.isSpeakerEnabled,
                inputLevelHistory: callSession.inputLevelHistory,
                lastLocalTranscript: "",
                lastServerTranscript: callSession.lastServerTranscript,
                recentTranscripts: [],
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
            onOpenSettings: {
                isSettingsPresented = true
            },
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
    let ensureServerStarted: () async -> Void
    @ObservedObject var callSession: MacCallSessionViewModel
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore

    private var transitionPhase: TincanCallTransitionPhase {
        guard callSession.isTransitioningCallState else { return .none }
        if callSession.callStateDescription == "Ending" {
            return .ending
        }
        return .starting
    }

    var body: some View {
        TincanAppSurface(
            callState: TincanCallPresentationState(
                callStateDescription: callSession.callStateDescription,
                isCallActive: callSession.isCallActive,
                isTransitioning: callSession.isTransitioningCallState,
                transitionPhase: transitionPhase,
                callStartedAt: callSession.callStartedAt,
                isMuted: callSession.isMuted,
                isSpeakerEnabled: callSession.isSpeakerEnabled,
                inputLevelHistory: callSession.inputLevelHistory,
                lastLocalTranscript: callSession.lastLocalTranscript,
                lastServerTranscript: callSession.lastServerTranscript,
                recentTranscripts: callSession.recentTranscripts,
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
                beginSpeakerIdentification: nil,
                resetSpeakerProfile: nil
            ),
            speechSettings: speechSettings,
            workspace: workspace,
            serverSettings: serverSettings,
            onOpenSettings: {},
            settingsTitle: "Settings",
            allowSettingsEditing: true,
            isSettingsPresented: .constant(false)
        )
        .frame(minWidth: 880, minHeight: 680)
        .task {
            await ensureServerStarted()
            workspace.start()
            await serverSettings.refreshHealth()
        }
    }
}
#endif

private struct TincanAppSurface: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions
#if os(macOS)
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
#endif
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
    let onOpenSettings: () -> Void
    let settingsTitle: String
    let allowSettingsEditing: Bool
    @Binding var isSettingsPresented: Bool

    private var selectedConversation: TincanConversationSummary? {
        guard let selectedConversationID = workspace.selectedConversationID else { return nil }
        return workspace.conversation(for: selectedConversationID)
    }

    var body: some View {
        TincanCanvas {
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
                    isLoadingConversations: workspace.isLoadingConversationList,
                    conversationListError: workspace.conversationListError,
                    highlightedLiveUpdate: workspace.highlightedLiveUpdate,
                    callState: callState,
                    onOpenSettings: onOpenSettings,
                    onOpenTranscript: { conversation in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            workspace.openConversation(conversation.id)
                        }
                    },
                    onRefresh: {
                        await workspace.refreshAll()
                    },
                    callActions: callActions
                )
#if os(iOS)
                .frame(maxWidth: 980, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
#else
                .frame(maxWidth: 980)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
#endif
            }
        }
#if os(iOS)
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
        }
#endif
    }
}

private struct TincanHomeScreen: View {
    let conversations: [TincanConversationSummary]
    let isLoadingConversations: Bool
    let conversationListError: String?
    let highlightedLiveUpdate: TincanHighlightedLiveUpdate?
    let callState: TincanCallPresentationState
    let onOpenSettings: () -> Void
    let onOpenTranscript: (TincanConversationSummary) -> Void
    let onRefresh: () async -> Void
    let callActions: TincanCallActions

    @State private var scrollOffset: CGFloat = 0

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

    private var shouldShowStandaloneTranscriptCard: Bool {
#if os(macOS)
        return false
#else
        let hasTranscript = !callState.lastServerTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTranscript
#endif
    }

    private var shouldShowScrollToTopButton: Bool {
        scrollOffset > 220
    }

    @ViewBuilder
    private var homeFeed: some View {
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

#if os(macOS)
                Button {
                    Task {
                        await onRefresh()
                    }
                } label: {
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
#endif
            }

            if conversations.isEmpty {
                if isLoadingConversations {
                    TincanLoadingConversationsCard()
                } else if let conversationListError, !conversationListError.isEmpty {
                    TincanConnectionFailureCard(
                        message: conversationListError,
                        onRetry: onRefresh
                    )
                } else {
                    TincanEmptyConversationsCard(isCallActive: callState.isCallActive)
                }
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

        if shouldShowStandaloneTranscriptCard {
            TincanLastTranscriptCard(text: callState.lastServerTranscript)
        }
    }

    var body: some View {
#if os(iOS)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                Color.clear
                    .frame(height: 1)
                    .id(TincanScrollAnchor.homeTop)

                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    TincanHomeHeader(
                        onOpenSettings: onOpenSettings
                    )
                    .padding(.top, 8)

                    Section {
                        VStack(alignment: .leading, spacing: 18) {
                            homeFeed
                        }
                    } header: {
                        TincanPinnedCallControlsHeader(
                            callState: callState,
                            callActions: callActions
                        )
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                geometry.visibleRect.minY
            }) { _, newValue in
                scrollOffset = max(0, newValue)
            }
            .overlay(alignment: .bottomTrailing) {
                if shouldShowScrollToTopButton {
                    TincanScrollToTopButton {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(TincanScrollAnchor.homeTop, anchor: .top)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .refreshable {
                await onRefresh()
            }
            .animation(.easeOut(duration: 0.2), value: shouldShowScrollToTopButton)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
#else
        VStack(alignment: .leading, spacing: 18) {
            TincanMacCallTranscriptCard(
                callState: callState,
                callActions: callActions
            )

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Color.clear
                        .frame(height: 1)
                        .id(TincanScrollAnchor.homeTop)

                    VStack(alignment: .leading, spacing: 18) {
                        homeFeed
                    }
                    .padding(.bottom, 24)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                    geometry.visibleRect.minY
                }) { _, newValue in
                    scrollOffset = max(0, newValue)
                }
                .overlay(alignment: .bottomTrailing) {
                    if shouldShowScrollToTopButton {
                        TincanScrollToTopButton {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                proxy.scrollTo(TincanScrollAnchor.homeTop, anchor: .top)
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: shouldShowScrollToTopButton)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#endif
    }
}

#if os(iOS)
private struct TincanPinnedCallControlsHeader: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions

    var body: some View {
        VStack(spacing: 0) {
            TincanCallControlPanel(
                callState: callState,
                callActions: callActions
            )
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }
}
#endif

private struct TincanHomeHeader: View {
    let onOpenSettings: () -> Void

    var body: some View {
#if os(macOS)
        brandMark
            .frame(maxWidth: .infinity, alignment: .leading)
#else
        HStack(alignment: .center, spacing: 16) {
            brandMark

            Spacer()

            TincanIconButton(systemImage: "gearshape.fill", tone: TincanPalette.panelRaised, action: onOpenSettings)
        }
#endif
    }

    private var brandMark: some View {
        HStack(spacing: 0) {
            Text("tin")
                .foregroundStyle(TincanPalette.textPrimary)
            Text("can")
                .foregroundStyle(TincanTone.mint.accent)
        }
        .font(.system(size: 30, weight: .heavy, design: .rounded))
    }
}

#if os(macOS)
private struct TincanMacCallTranscriptCard: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions

    private var statusTone: Color {
        callState.isCallActive ? TincanTone.mint.accent : TincanTone.blue.accent
    }

    private var isIdle: Bool {
        !callState.isCallActive && !callState.isTransitioning
    }

    private var isStartingOrCanceling: Bool {
        callState.isTransitioning && !callState.isCallActive
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            HStack(alignment: .center, spacing: 24) {
                logoColumn

                leftColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TincanTranscriptTicker(transcripts: callState.recentTranscripts)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logoColumn: some View {
        HStack(spacing: 0) {
            Text("tin")
                .foregroundStyle(TincanPalette.textPrimary)
            Text("can")
                .foregroundStyle(TincanTone.mint.accent)
        }
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var leftColumn: some View {
        if isIdle {
            TincanMacStartCallButton(action: callActions.startCall)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                if isStartingOrCanceling {
                    TincanMacStageProgressBadge(accent: statusTone)
                } else {
                    TincanMacStageButton(
                        systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                        foreground: callState.isMuted ? TincanTone.amber.accent : TincanPalette.textPrimary,
                        background: TincanPalette.panelRaised,
                        border: callState.isMuted ? TincanTone.amber.accent.opacity(0.28) : TincanPalette.shellBorder,
                        action: callActions.toggleMute
                    )
                    .disabled(!callState.isCallActive)
                }

                TincanMacCallMeter(callState: callState, accent: statusTone)
                    .frame(maxWidth: .infinity)

                TincanMacStageButton(
                    systemImage: isStartingOrCanceling ? "xmark" : "phone.down.fill",
                    foreground: TincanPalette.textPrimary,
                    background: TincanPalette.callRed,
                    border: TincanPalette.callRed.opacity(0.72),
                    action: callActions.endCall
                )
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TincanTranscriptTicker: View {
    let transcripts: [TincanTranscriptDisplayItem]

    private let visibleRowCount = 3
    private let rowHeight: CGFloat = 17
    private let rowSpacing: CGFloat = 3

    private var visibleTranscripts: [TincanTranscriptDisplayItem] {
        Array(transcripts.prefix(visibleRowCount))
    }

    private var tickerHeight: CGFloat {
        CGFloat(visibleRowCount) * rowHeight + CGFloat(visibleRowCount - 1) * rowSpacing
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if visibleTranscripts.isEmpty {
                Text(#"Say "Atlas, get me top 3 headlines from Hacker News""#)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .italic()
                    .foregroundStyle(TincanPalette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            } else {
                VStack(alignment: .trailing, spacing: rowSpacing) {
                    ForEach(Array(visibleTranscripts.enumerated()), id: \.element.id) { index, transcript in
                        TincanTranscriptTickerRow(
                            transcript: transcript,
                            prominence: index == 0 ? .primary : .secondary
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: tickerHeight, alignment: .center)
        .animation(.spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.08), value: visibleTranscripts)
    }
}

private struct TincanTranscriptTickerRow: View {
    enum Prominence {
        case primary
        case secondary
    }

    let transcript: TincanTranscriptDisplayItem
    let prominence: Prominence

    private var foregroundColor: Color {
        if transcript.state == .approvedForUpload {
            return TincanPalette.emerald500
        }
        switch prominence {
        case .primary:
            return TincanPalette.textPrimary
        case .secondary:
            return TincanPalette.textSecondary
        }
    }

    private var fontSize: CGFloat {
        prominence == .primary ? 14 : 11
    }

    var body: some View {
        Text(#""\#(transcript.text)""#)
            .font(.system(size: fontSize, weight: prominence == .primary ? .regular : .medium, design: .default))
            .italic()
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, minHeight: 17, alignment: .trailing)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                )
            )
    }
}

private struct TincanMacStartCallButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("call")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(TincanPalette.textOnAccent)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(
                Capsule(style: .continuous)
                    .fill(TincanTone.mint.accent)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TincanMacCallStage: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions

    private let collapsedSize = CGSize(width: 84, height: 40)
    private let expandedSize = CGSize(width: 344, height: 72)

    private var isExpanded: Bool {
        callState.isCallActive || callState.isTransitioning
    }

    private var isStartingOrCanceling: Bool {
        callState.isTransitioning && !callState.isCallActive
    }

    private var statusTone: Color {
        callState.isCallActive ? TincanTone.mint.accent : TincanTone.blue.accent
    }

    var body: some View {
        Group {
            if isExpanded {
                HStack(spacing: 10) {
                    if isStartingOrCanceling {
                        TincanMacStageProgressBadge(accent: statusTone)
                    } else {
                        TincanMacStageButton(
                            systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                            foreground: callState.isMuted ? TincanTone.amber.accent : TincanPalette.textPrimary,
                            background: TincanPalette.panelRaised,
                            border: callState.isMuted ? TincanTone.amber.accent.opacity(0.28) : TincanPalette.shellBorder,
                            action: callActions.toggleMute
                        )
                        .disabled(!callState.isCallActive)
                    }

                    TincanMacCallMeter(callState: callState, accent: statusTone)

                    TincanMacStageButton(
                        systemImage: isStartingOrCanceling ? "xmark" : "phone.down.fill",
                        foreground: TincanPalette.textPrimary,
                        background: TincanPalette.callRed,
                        border: TincanPalette.callRed.opacity(0.72),
                        action: callActions.endCall
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
            } else {
                Button(action: callActions.startCall) {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("call")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(TincanPalette.textOnAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(callState.isTransitioning)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.02)), removal: .opacity))
            }
        }
        .frame(
            width: isExpanded ? expandedSize.width : collapsedSize.width,
            height: isExpanded ? expandedSize.height : collapsedSize.height
        )
        .background(stageBackground)
        .overlay(stageBorder)
        .shadow(color: statusTone.opacity(isExpanded ? 0.16 : 0.10), radius: isExpanded ? 20 : 10, x: 0, y: 8)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeOut(duration: 0.18), value: callState.isMuted)
    }

    private var stageBackground: some View {
        RoundedRectangle(cornerRadius: isExpanded ? 28 : 20, style: .continuous)
            .fill(isExpanded ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        TincanPalette.panelMuted.opacity(0.98),
                        TincanPalette.panel.opacity(0.96)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ) : AnyShapeStyle(TincanTone.mint.accent))
    }

    private var stageBorder: some View {
        RoundedRectangle(cornerRadius: isExpanded ? 28 : 20, style: .continuous)
            .stroke(
                isExpanded ? statusTone.opacity(0.34) : TincanTone.mint.accent.opacity(0),
                lineWidth: 1
            )
    }
}

private struct TincanMacCallMeter: View {
    let callState: TincanCallPresentationState
    let accent: Color

    private var durationLabel: String? {
        callDurationLabel(
            startedAt: callState.callStartedAt,
            isCallActive: callState.isCallActive,
            isTransitioning: callState.isTransitioning
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let callStartedAt = callState.callStartedAt, callState.isCallActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedLabel(since: callStartedAt))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(TincanPalette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else if let durationLabel {
                    Text(durationLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(callState.isTransitioning ? accent : TincanPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(callState.callStateDescription.lowercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(callState.isTransitioning ? accent : TincanPalette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            TincanWaveStrip(levels: callState.inputLevelHistory, accent: accent)
                .padding(.vertical, 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TincanMacStageProgressBadge: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(TincanPalette.panelRaised)
                .overlay(
                    Circle()
                        .stroke(accent.opacity(0.34), lineWidth: 1)
                )

            ProgressView()
                .controlSize(.small)
                .tint(accent)
        }
        .frame(width: 48, height: 48)
    }
}

private struct TincanMacStageButton: View {
    let systemImage: String
    let foreground: Color
    let background: Color
    let border: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(background)
                        .overlay(
                            Circle()
                                .stroke(border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
#endif

private struct TincanCallControlPanel: View {
    let callState: TincanCallPresentationState
    let callActions: TincanCallActions

    private var isIdle: Bool {
        !callState.isCallActive && !callState.isTransitioning
    }

    private var isStarting: Bool {
        callState.isStartingTransition
    }

    private var accent: Color {
        if callState.isEndingTransition {
            return TincanPalette.callRed
        }
        if callState.isStartingTransition {
            return TincanTone.blue.accent
        }
        return callState.isCallActive ? TincanTone.mint.accent : TincanPalette.shellBorder
    }

    private var durationLabel: String? {
        callDurationLabel(
            startedAt: callState.callStartedAt,
            isCallActive: callState.isCallActive,
            isTransitioning: callState.isTransitioning
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isIdle ? 0 : 14) {
            if isIdle {
                HStack {
                    Spacer()

                    Button(action: callActions.startCall) {
                        HStack(spacing: 10) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("call")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(TincanPalette.textOnAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(
                            Capsule(style: .continuous)
                                .fill(TincanTone.mint.accent)
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                        Text(callState.callStateDescription.lowercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }

                    Spacer()

                    if let callStartedAt = callState.callStartedAt, callState.isCallActive {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(elapsedLabel(since: callStartedAt))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(TincanPalette.textSecondary)
                        }
                    } else if let durationLabel {
                        Text(durationLabel)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(TincanPalette.textSecondary)
                    }
                }

                HStack(spacing: 12) {
                    TincanMiniControlButton(
                        systemImage: callState.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        label: "speaker",
                        tone: TincanTone.blue.accent,
                        isEnabled: callState.isCallActive,
                        action: callActions.toggleSpeaker
                    )

                    TincanMiniControlButton(
                        systemImage: isStarting ? "xmark" : "phone.down.fill",
                        label: isStarting ? "cancel" : "disconnect",
                        tone: TincanPalette.callRed,
                        action: callActions.endCall
                    )

                    TincanMiniControlButton(
                        systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: "mute",
                        tone: TincanTone.amber.accent,
                        isEnabled: callState.isCallActive,
                        action: callActions.toggleMute
                    )
                }

                Group {
                    if callState.isTransitioning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        TincanWaveStrip(levels: callState.inputLevelHistory, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TincanPalette.panelMuted.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(accent.opacity(isIdle ? 0.18 : 0.28), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: callState.isMuted)
        .animation(.easeOut(duration: 0.18), value: callState.isSpeakerEnabled)
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

private struct TincanConnectionFailureCard: View {
    let message: String
    let onRetry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Can't reach server")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            Text("Connection to the server failed. Check that the server is running, then retry.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(TincanPalette.textSecondary)

            Text(message)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TincanTone.coral.accent)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TincanTone.coral.tint.opacity(0.52))
                )

            Button {
                guard !isRetrying else { return }
                isRetrying = true

                Task {
                    await onRetry()
                    await MainActor.run {
                        isRetrying = false
                    }
                }
            } label: {
                Text(isRetrying ? "Retrying..." : "Retry connection")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TincanPalette.panelRaised)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

private struct TincanLoadingConversationsCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(TincanTone.blue.accent)

            VStack(alignment: .leading, spacing: 6) {
                Text("Loading conversations")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)

                Text("Fetching threads from the server.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            Spacer()
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

    @State private var scrollOffset: CGFloat = 0

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

    private var shouldShowScrollToTopButton: Bool {
        scrollOffset > 180
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
                    Color.clear
                        .frame(height: 1)
                        .id(TincanScrollAnchor.transcriptTop)

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
                .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                    geometry.visibleRect.minY
                }) { _, newValue in
                    scrollOffset = max(0, newValue)
                }
                .overlay(alignment: .bottomTrailing) {
                    if shouldShowScrollToTopButton {
                        TincanScrollToTopButton {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                proxy.scrollTo(TincanScrollAnchor.transcriptTop, anchor: .top)
                            }
                        }
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: shouldShowScrollToTopButton)
                .onAppear {
                    scrollToLatest(proxy: proxy)
                }
                .onChange(of: timelineMessages.last?.id) { _, _ in
                    scrollToLatest(proxy: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TincanPalette.shell.opacity(0.78))
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

    private var agentStatusAccent: Color {
        switch conversation.agentProcessStatus {
        case .running:
            return TincanTone.mint.accent
        case .idle:
            return TincanPalette.textMuted
        }
    }

    private var agentStatusAccessibilityLabel: String {
        "Agent \(conversation.agentProcessStatus.rawValue)"
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

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(agentStatusAccent)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text(conversation.handle)
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(TincanPalette.textPrimary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(conversation.handle), \(agentStatusAccessibilityLabel)")

                    Text(shortDirectoryName(conversation.workingDirectory))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(TincanPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

#if os(macOS)
                TincanMacCallStage(callState: callState, callActions: callActions)
#else
                if callState.isCallActive || callState.isTransitioning {
                    HStack(spacing: 10) {
                        if callState.isCallActive {
                            TincanMiniHeaderButton(
                                systemImage: callState.isSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                action: callActions.toggleSpeaker
                            )
                            TincanMiniHeaderButton(
                                systemImage: callState.isMuted ? "mic.slash.fill" : "mic.fill",
                                action: callActions.toggleMute
                            )
                        }
                        TincanMiniHeaderButton(
                            systemImage: callState.isStartingTransition ? "xmark" : "phone.down.fill",
                            destructive: true,
                            action: callActions.endCall
                        )
                    }
                } else {
                    TincanToolbarButton(
                        label: "call",
                        systemImage: "phone.fill",
                        tone: TincanTone.mint.accent,
                        foreground: TincanPalette.textOnAccent,
                        action: callActions.startCall
                    )
                    .disabled(callState.isTransitioning)
                }
#endif
            }
        }
        .padding(18)
        .background(TincanPalette.panelMuted.opacity(0.97))
    }
}

private struct TincanScrollToTopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(TincanPalette.textPrimary)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(TincanPalette.panelRaised.opacity(0.96))
                        .overlay(
                            Circle()
                                .stroke(TincanTone.blue.accent.opacity(0.34), lineWidth: 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 16, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to top")
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

private enum TincanSettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case connectPhone
    case agentBackends
    case agentServices
    case speech
    case services
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectPhone:
            return "Connect Phone"
        case .agentBackends:
            return "Agent Backends"
        case .agentServices:
            return "Agent Services"
        case .speech:
            return "Speech"
        case .services:
            return "Services"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .connectPhone:
            return "iphone.gen3.radiowaves.left.and.right"
        case .agentBackends:
            return "square.stack.3d.up.fill"
        case .agentServices:
            return "person.2.fill"
        case .speech:
            return "waveform"
        case .services:
            return "switch.2"
        case .diagnostics:
            return "stethoscope"
        }
    }

    var showsSpeechSettingsBottomBar: Bool {
        switch self {
        case .speech, .services:
            return true
        case .connectPhone, .agentBackends, .agentServices, .diagnostics:
            return false
        }
    }
}

#if os(iOS)
private struct TincanSettingsScreen: View {
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
    let callState: TincanCallPresentationState
    let title: String
    let allowEditing: Bool
    let onDismiss: () -> Void

    var body: some View {
        TincanCanvas {
            NavigationStack {
                List(TincanSettingsDestination.allCases) { destination in
                    NavigationLink(value: destination) {
                        TincanSettingsSidebarRow(destination: destination)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: TincanSettingsDestination.self) { destination in
                    TincanSettingsPageLayout {
                        TincanSettingsDestinationContent(
                            destination: destination,
                            workspace: workspace,
                            serverSettings: serverSettings,
                            callState: callState,
                            allowEditing: allowEditing
                        )
                    }
                    .navigationTitle(destination.title)
                    .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDismiss)
                    }
                }
            }
        }
    }
}
#endif

#if os(macOS)
struct TincanMacSettingsWindow: View {
    @ObservedObject var callSession: MacCallSessionViewModel
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
    @State private var selectedDestination: TincanSettingsDestination? = .connectPhone

    private var transitionPhase: TincanCallTransitionPhase {
        guard callSession.isTransitioningCallState else { return .none }
        if callSession.callStateDescription == "Ending" {
            return .ending
        }
        return .starting
    }

    private var callState: TincanCallPresentationState {
        TincanCallPresentationState(
            callStateDescription: callSession.callStateDescription,
            isCallActive: callSession.isCallActive,
            isTransitioning: callSession.isTransitioningCallState,
            transitionPhase: transitionPhase,
            callStartedAt: callSession.callStartedAt,
            isMuted: callSession.isMuted,
            isSpeakerEnabled: callSession.isSpeakerEnabled,
            inputLevelHistory: callSession.inputLevelHistory,
            lastLocalTranscript: callSession.lastLocalTranscript,
            lastServerTranscript: callSession.lastServerTranscript,
            recentTranscripts: callSession.recentTranscripts,
            logLines: callSession.logLines,
            speakerIdentity: TincanSpeakerIdentityPresentation(
                phase: callSession.speakerIdentityPhase,
                title: speakerIdentityTitle(for: callSession.speakerIdentityPhase),
                description: callSession.identityStatusDescription,
                detail: callSession.ownerProfileDescription
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            List(TincanSettingsDestination.allCases, selection: $selectedDestination) { destination in
                TincanSettingsSidebarRow(destination: destination)
                    .tag(destination)
            }
            .navigationTitle("Settings")
            .frame(minWidth: 220)
        } detail: {
            Group {
                if let selectedDestination {
                    TincanSettingsPageLayout {
                        TincanSettingsDetailHeading(title: selectedDestination.title)
                        TincanSettingsDestinationContent(
                            destination: selectedDestination,
                            workspace: workspace,
                            serverSettings: serverSettings,
                            speechSettings: speechSettings,
                            callState: callState,
                            allowEditing: true,
                            showsPageCardTitle: false
                        )
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if selectedDestination.showsSpeechSettingsBottomBar {
                            TincanSpeechSettingsBottomBar(speechSettings: speechSettings)
                        }
                    }
                } else {
                    TincanSettingsPageLayout {
                        TincanSettingsSelectionPlaceholder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 620)
        .task(id: serverSettings.connectionRevision) {
            await speechSettings.load()
        }
    }
}
#endif

private struct TincanSettingsDestinationContent: View {
    let destination: TincanSettingsDestination
    @ObservedObject var workspace: TincanWorkspaceStore
    @ObservedObject var serverSettings: ServerConnectionStore
#if os(macOS)
    @ObservedObject var speechSettings: TincanSpeechSettingsStore
#endif
    let callState: TincanCallPresentationState
    let allowEditing: Bool
    var showsPageCardTitle: Bool = true

    @ViewBuilder
    var body: some View {
        switch destination {
        case .connectPhone:
            TincanServerSettingsSection(
                title: showsPageCardTitle ? "Connect phone" : nil,
                serverSettings: serverSettings,
                onApplyConnection: {
                    let changed = serverSettings.applyRemoteDraft()
                    if changed {
                        Task {
                            await workspace.refreshAll()
                        }
                    }
                }
            )

        case .agentBackends:
            TincanSettingsSection(
                title: showsPageCardTitle ? "Agent backends" : nil,
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

        case .agentServices:
            TincanSettingsSection(
                title: showsPageCardTitle ? "Agent services" : nil,
                subtitle: allowEditing ? "Server-backed routing profiles for conversations." : "Read-only on iPhone."
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

        case .speech:
#if os(macOS)
            TincanSpeechPageContent(
                speechSettings: speechSettings,
                showsPageCardTitle: showsPageCardTitle
            )
#else
            TincanSettingsUnavailableCard(
                title: "Speech",
                message: "Speech model selection is configured from the Mac app because the bundled speech server runs there."
            )
#endif

        case .services:
#if os(macOS)
            TincanServicesPageContent(
                speechSettings: speechSettings,
                showsPageCardTitle: showsPageCardTitle
            )
#else
            TincanSettingsUnavailableCard(
                title: "Services",
                message: "Provider credentials and local service toggles are managed from the Mac app."
            )
#endif

        case .diagnostics:
            TincanSettingsSection(title: showsPageCardTitle ? "Diagnostics" : nil) {
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
                            .font(TincanSettingsTypography.body)
                            .foregroundStyle(TincanTone.coral.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !callState.lastServerTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Last transcript")
                                .font(TincanSettingsTypography.emphasis)
                                .foregroundStyle(TincanPalette.textSecondary)
                            Text(callState.lastServerTranscript)
                                .font(TincanSettingsTypography.body)
                                .foregroundStyle(TincanPalette.textSecondary)
                        }
                    }

                    if !callState.logLines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent activity")
                                .font(TincanSettingsTypography.emphasis)
                                .foregroundStyle(TincanPalette.textSecondary)

                            ForEach(Array(callState.logLines.prefix(6).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(TincanSettingsTypography.body)
                                    .foregroundStyle(TincanPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TincanSettingsSidebarRow: View {
    let destination: TincanSettingsDestination

    var body: some View {
        Label(destination.title, systemImage: destination.systemImage)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(TincanPalette.textPrimary)
            .padding(.vertical, 4)
    }
}

private struct TincanSettingsDetailHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TincanSettingsTypography.pageTitle)
            .foregroundStyle(TincanPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TincanSettingsPageLayout<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .frame(maxWidth: 940)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct TincanSettingsSelectionPlaceholder: View {
    var body: some View {
        TincanSettingsSection(
            title: "Select a page",
            subtitle: "Choose a settings category from the sidebar."
        ) {
            Text("Split settings into smaller pages so each category is easier to scan and maintain.")
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TincanSettingsUnavailableCard: View {
    let title: String
    let message: String

    var body: some View {
        TincanSettingsSection(
            title: title,
            subtitle: "This page is configured from the Mac app."
        ) {
            Text(message)
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TincanServerSettingsSection: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ObservedObject var serverSettings: ServerConnectionStore
    let onApplyConnection: () -> Void

    var body: some View {
        TincanSettingsSection(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
#if os(macOS)
                    TincanServerModeChip(
                        label: ServerConnectionStore.ConnectionMode.localMac.title,
                        isSelected: serverSettings.connectionMode == .localMac
                    ) {
                        serverSettings.setConnectionMode(.localMac)
                    }
#endif
                    TincanServerModeChip(
                        label: ServerConnectionStore.ConnectionMode.remote.title,
                        isSelected: serverSettings.connectionMode == .remote
                    ) {
                        serverSettings.setConnectionMode(.remote)
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

                        if serverSettings.connectionMode == .remote {
                            VStack(alignment: .leading, spacing: 10) {
                                TincanLabeledField(label: "Host", text: $serverSettings.draftHost)
                                TincanLabeledField(label: "Port", text: $serverSettings.draftPort)

                                Button("Apply", action: onApplyConnection)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                            }
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
                    .font(TincanSettingsTypography.emphasis)
                    .foregroundStyle(TincanPalette.textPrimary)
                Text("\(backend.type) · \(backend.options.model)")
                    .font(TincanSettingsTypography.body)
                    .foregroundStyle(TincanPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(backend.options.connectionType.isEmpty ? "server" : backend.options.connectionType)
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanTone.blue.accent)
        }
        .padding(.vertical, 4)
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
                    .font(TincanSettingsTypography.emphasis)
                    .foregroundStyle(TincanPalette.textPrimary)
                Text(shortDirectoryName(profile.workingDirectory))
                    .font(TincanSettingsTypography.body)
                    .foregroundStyle(TincanPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(profile.agentBackend)
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanTone.blue.accent)
        }
        .padding(.vertical, 4)
    }
}

private struct TincanSettingsPlaceholderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TincanSettingsTypography.body)
            .foregroundStyle(TincanPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TincanSettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textSecondary)
            Spacer()
            Text(value)
                .font(TincanSettingsTypography.emphasis)
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
                .font(TincanSettingsTypography.emphasis)
                .foregroundStyle(TincanPalette.textSecondary)

            TextField("", text: $text)
                .font(TincanSettingsTypography.body)
                .textFieldStyle(.roundedBorder)
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
                                .font(TincanSettingsTypography.body)
                                .foregroundStyle(TincanPalette.textSecondary)
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
                .font(TincanSettingsTypography.body)
                .foregroundStyle(TincanPalette.textSecondary)
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
    elapsedLabel(since: startDate, now: Date())
}

func callDurationLabel(
    startedAt: Date?,
    isCallActive: Bool,
    isTransitioning: Bool,
    now: Date = Date()
) -> String? {
    if let startedAt, isCallActive {
        return elapsedLabel(since: startedAt, now: now)
    }

    if isCallActive || isTransitioning {
        return "--:--:--"
    }

    return nil
}

private func elapsedLabel(since startDate: Date, now: Date) -> String {
    let elapsed = max(0, Int(now.timeIntervalSince(startDate)))
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
    case .connected:
        return "ok"
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
        return "Wake Word"
    case .awaitingChallengeResponse:
        return "Ambiguous"
    case .ownerVerified:
        return "Speaker Matched"
    case .unavailable:
        return "Unavailable"
    }
}
