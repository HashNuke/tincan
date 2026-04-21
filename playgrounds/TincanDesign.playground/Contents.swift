import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(PlaygroundSupport)
import PlaygroundSupport
#endif

private enum DemoScreen: String, CaseIterable, Identifiable {
    case home = "Home"
    case transcript = "Transcript"
    case settings = "Settings"

    var id: String { rawValue }
}

private enum ConversationTone: String {
    case mint
    case blue
    case amber
    case coral

    var accent: Color {
        switch self {
        case .mint:
            return Color(red: 0.38, green: 0.95, blue: 0.72)
        case .blue:
            return Color(red: 0.43, green: 0.72, blue: 1.00)
        case .amber:
            return Color(red: 0.99, green: 0.80, blue: 0.36)
        case .coral:
            return Color(red: 0.98, green: 0.54, blue: 0.47)
        }
    }

    var tint: Color {
        accent.opacity(0.16)
    }
}

private struct DemoConversation: Identifiable, Equatable {
    let id: String
    let handle: String
    let agentName: String
    let workingDirectory: String
    let preview: String
    let updatedLabel: String 
    let tone: ConversationTone
    let hasUnreadTextUpdate: Bool
    let activityLabel: String
    let note: String

    var shortDirectoryName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }
}

private enum TimelineKind {
    case user
    case agent
    case updateCard
}

private struct TimelineItem: Identifiable {
    let id: String
    let kind: TimelineKind
    let title: String
    let body: String
    let timestamp: String
    let caption: String?
    let codeSnippet: String?
}

private enum SampleData {
    static let conversations: [DemoConversation] = [
        DemoConversation(
            id: "emma#16",
            handle: "emma#16",
            agentName: "emma",
            workingDirectory: "/Users/akash/code/apple/tincan",
            preview: "Finished the call-routing pass. There is a patch ready and one UI follow-up.",
            updatedLabel: "just now",
            tone: .mint,
            hasUnreadTextUpdate: true,
            activityLabel: "current",
            note: "3 files changed"
        ),
        DemoConversation(
            id: "atlas#7",
            handle: "atlas#7",
            agentName: "atlas",
            workingDirectory: "/Users/akash/sources/opencode",
            preview: "I mapped the server hooks. Transcript history still needs an app-facing API.",
            updatedLabel: "4m",
            tone: .blue,
            hasUnreadTextUpdate: true,
            activityLabel: "update",
            note: "needs review"
        ),
        DemoConversation(
            id: "emma#12",
            handle: "emma#12",
            agentName: "emma",
            workingDirectory: "/Users/akash/code/apple/tincan",
            preview: "Speaker diarization thresholds look stable after the last run.",
            updatedLabel: "18m",
            tone: .amber,
            hasUnreadTextUpdate: false,
            activityLabel: "idle",
            note: "voice profile"
        ),
        DemoConversation(
            id: "atlas#3",
            handle: "atlas#3",
            agentName: "atlas",
            workingDirectory: "/Users/akash/sources/opencode",
            preview: "Router prompt changes landed. Waiting for a new voice command to test.",
            updatedLabel: "52m",
            tone: .coral,
            hasUnreadTextUpdate: false,
            activityLabel: "idle",
            note: "router"
        ),
    ]

    static let transcript: [String: [TimelineItem]] = [
        "emma#16": [
            TimelineItem(
                id: "e16-1",
                kind: .user,
                title: "You",
                body: "Emma, make the home screen keep the conversation list visible while a call is active.",
                timestamp: "2:04 PM",
                caption: nil,
                codeSnippet: nil
            ),
            TimelineItem(
                id: "e16-2",
                kind: .agent,
                title: "emma#16",
                body: "I am on it. I am treating the active-call dashboard as the live state of the home screen instead of a separate route.",
                timestamp: "2:04 PM",
                caption: "call live",
                codeSnippet: nil
            ),
            TimelineItem(
                id: "e16-3",
                kind: .agent,
                title: "emma#16",
                body: "I also promoted the current call thread into a larger card so the list keeps context without losing the rest of the threads.",
                timestamp: "2:08 PM",
                caption: nil,
                codeSnippet: nil
            ),
            TimelineItem(
                id: "e16-4",
                kind: .updateCard,
                title: "Update",
                body: "Home flow updated. The active thread stays featured during the call and the latest thread updates stay visible in the list.",
                timestamp: "2:11 PM",
                caption: "3 files changed",
                codeSnippet: """
struct ActiveHomeView: View {
    let featuredConversation: ConversationSummary
    let conversations: [ConversationSummary]
}
"""
            )
        ],
        "atlas#7": [
            TimelineItem(
                id: "a7-1",
                kind: .user,
                title: "You",
                body: "Atlas, map the API we need for the conversation list and update history.",
                timestamp: "1:44 PM",
                caption: nil,
                codeSnippet: nil
            ),
            TimelineItem(
                id: "a7-2",
                kind: .agent,
                title: "atlas#7",
                body: "Minimum shape: one list endpoint for conversations, one endpoint for per-thread updates, and SSE to merge live events into fetched history.",
                timestamp: "1:45 PM",
                caption: nil,
                codeSnippet: nil
            ),
            TimelineItem(
                id: "a7-3",
                kind: .updateCard,
                title: "Update",
                body: "I mapped the first pass of the API. The app needs thread summaries and per-thread update history.",
                timestamp: "1:48 PM",
                caption: "api",
                codeSnippet: """
GET /conversations
GET /conversations/{handle}/updates
"""
            )
        ]
    ]

    static let backendRows: [(String, String)] = [
        ("opencode-1", "OpenCode · local backend"),
        ("codex-1", "Codex · localhost:5371"),
        ("__router__", "OpenCode router backend"),
    ]

    static let profileRows: [(String, String, String)] = [
        ("emma", "/Users/akash/code/apple/tincan", "opencode-1"),
        ("atlas", "/Users/akash/sources/opencode", "codex-1"),
    ]
}

private enum Palette {
    static let canvasTop = Color(red: 0.09, green: 0.12, blue: 0.14)
    static let canvasBottom = Color(red: 0.03, green: 0.05, blue: 0.08)
    static let shell = Color(red: 0.05, green: 0.08, blue: 0.11)
    static let shellBorder = Color.white.opacity(0.10)
    static let panel = Color(red: 0.09, green: 0.13, blue: 0.17)
    static let panelRaised = Color(red: 0.12, green: 0.17, blue: 0.22)
    static let panelMuted = Color(red: 0.07, green: 0.10, blue: 0.14)
    static let textPrimary = Color(red: 0.92, green: 0.95, blue: 0.98)
    static let textSecondary = Color(red: 0.61, green: 0.69, blue: 0.76)
    static let textMuted = Color(red: 0.40, green: 0.47, blue: 0.54)
    static let divider = Color.white.opacity(0.08)
    static let callRed = Color(red: 0.77, green: 0.23, blue: 0.28)
}

private func shortDirectoryName(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

private struct DesignPlaygroundView: View {
    @State private var screen: DemoScreen = .home
    @State private var isCallActive = true
    @State private var isMuted = false
    @State private var speakerEnabled = true
    @State private var selectedConversationID = "emma#16"
    @State private var currentCallConversationID = "emma#16"

    private let conversations = SampleData.conversations

    private var selectedConversation: DemoConversation {
        conversations.first(where: { $0.id == selectedConversationID }) ?? conversations[0]
    }

    private var currentConversation: DemoConversation? {
        conversations.first(where: { $0.id == currentCallConversationID })
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.canvasTop, Palette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.18, green: 0.34, blue: 0.28).opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: -120, y: -260)

            DeviceShell {
                switch screen {
                case .home:
                    HomeScreen(
                        conversations: conversations,
                        currentConversation: currentConversation,
                        selectedConversationID: selectedConversationID,
                        isCallActive: isCallActive,
                        isMuted: $isMuted,
                        speakerEnabled: $speakerEnabled,
                        onToggleCall: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                isCallActive.toggle()
                            }
                        },
                        onOpenSettings: {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                screen = .settings
                            }
                        },
                        onOpenTranscript: { conversation in
                            selectedConversationID = conversation.id
                            withAnimation(.easeInOut(duration: 0.22)) {
                                screen = .transcript
                            }
                        }
                    )
                case .transcript:
                    TranscriptScreen(
                        conversation: selectedConversation,
                        timeline: SampleData.transcript[selectedConversation.id] ?? [],
                        isCallActive: isCallActive,
                        isMuted: $isMuted,
                        speakerEnabled: $speakerEnabled,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                screen = .home
                            }
                        }
                    )
                case .settings:
                    SettingsScreen(
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                screen = .home
                            }
                        }
                    )
                }
            }
        }
        .frame(width: 460, height: 940)
    }
}

private struct DeviceShell<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(Palette.shell)
                .overlay(
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .stroke(Palette.shellBorder, lineWidth: 1.25)
                )
                .shadow(color: .black.opacity(0.40), radius: 32, x: 0, y: 24)

            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.09, blue: 0.12), Color(red: 0.04, green: 0.07, blue: 0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(12)

            content
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(12)
        }
        .frame(width: 432, height: 896)
    }
}

private struct HomeScreen: View {
    let conversations: [DemoConversation]
    let currentConversation: DemoConversation?
    let selectedConversationID: String
    let isCallActive: Bool
    @Binding var isMuted: Bool
    @Binding var speakerEnabled: Bool
    let onToggleCall: () -> Void
    let onOpenSettings: () -> Void
    let onOpenTranscript: (DemoConversation) -> Void

    private var otherConversations: [DemoConversation] {
        conversations.filter { $0.id != currentConversation?.id }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HomeHeader(
                    isCallActive: isCallActive,
                    onToggleCall: onToggleCall,
                    onOpenSettings: onOpenSettings
                )

                if isCallActive {
                    CallControlPanel(
                        elapsed: "2:11:04",
                        isMuted: $isMuted,
                        speakerEnabled: $speakerEnabled
                    )
                }

                if isCallActive, let currentConversation {
                    FeaturedConversationCard(
                        conversation: currentConversation,
                        isSelected: currentConversation.id == selectedConversationID,
                        onOpenTranscript: { onOpenTranscript(currentConversation) }
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("conversations")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text("\(conversations.count)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Palette.panel)
                            )
                    }

                    ForEach(otherConversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: conversation.id == selectedConversationID,
                            isCurrentCallConversation: false,
                            onOpenTranscript: { onOpenTranscript(conversation) }
                        )
                    }
                }

                if !isCallActive {
                    QuietStatusCard()
                }
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.11), Color(red: 0.04, green: 0.07, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct HomeHeader: View {
    let isCallActive: Bool
    let onToggleCall: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 0) {
                Text("tin")
                    .foregroundStyle(Palette.textPrimary)
                Text("can")
                    .foregroundStyle(ConversationTone.mint.accent)
            }
            .font(.system(size: 30, weight: .heavy, design: .rounded))

            Spacer()

            HStack(spacing: 10) {
                IconToolbarButton(
                    systemImage: "gearshape.fill",
                    tone: Palette.panelRaised
                ) {
                    onOpenSettings()
                }

                if !isCallActive {
                    Button(action: onToggleCall) {
                        HStack(spacing: 8) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("call")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.black.opacity(0.84))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            Capsule(style: .continuous)
                                .fill(ConversationTone.mint.accent)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct CallControlPanel: View {
    let elapsed: String
    @Binding var isMuted: Bool
    @Binding var speakerEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ConversationTone.mint.accent)
                        .frame(width: 8, height: 8)
                    Text("on call")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ConversationTone.mint.accent)
                }
                Spacer()
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
            }

            HStack(spacing: 12) {
                MiniControlButton(
                    systemImage: speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    label: "speaker",
                    tone: ConversationTone.blue.accent
                ) {
                    speakerEnabled.toggle()
                }

                MiniControlButton(
                    systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                    label: "mute",
                    tone: ConversationTone.amber.accent
                ) {
                    isMuted.toggle()
                }

                MiniControlButton(
                    systemImage: "phone.down.fill",
                    label: "end",
                    tone: Palette.callRed
                ) {}
            }

            WaveStrip(accent: ConversationTone.mint.accent)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Palette.panelMuted.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(ConversationTone.mint.accent.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct FeaturedConversationCard: View {
    let conversation: DemoConversation
    let isSelected: Bool
    let onOpenTranscript: () -> Void

    var body: some View {
        Button(action: onOpenTranscript) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            CapsuleTag(text: conversation.handle, tone: conversation.tone.accent)
                            CapsuleTag(text: "current", tone: conversation.tone.accent.opacity(0.8), filled: false)
                        }
                        Text(conversation.preview)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 10) {
                        Text(conversation.updatedLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.textPrimary.opacity(0.82))
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(conversation.tone.accent)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                conversation.tone.tint.opacity(1.0),
                                Palette.panelRaised.opacity(0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                isSelected ? conversation.tone.accent : conversation.tone.accent.opacity(0.45),
                                lineWidth: isSelected ? 1.6 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationRow: View {
    let conversation: DemoConversation
    let isSelected: Bool
    let isCurrentCallConversation: Bool
    let onOpenTranscript: () -> Void

    var borderColor: Color {
        if conversation.hasUnreadTextUpdate {
            return ConversationTone.amber.accent
        }
        if isSelected {
            return conversation.tone.accent
        }
        return Palette.shellBorder
    }

    var body: some View {
        Button(action: onOpenTranscript) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(conversation.tone.tint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(conversation.tone.accent.opacity(0.34), lineWidth: 1)
                        )
                    Text(String(conversation.agentName.prefix(2)).uppercased())
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundStyle(conversation.tone.accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(conversation.handle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.textPrimary)

                        Spacer()

                        Text(conversation.updatedLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                    }

                    Text(conversation.preview)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack {
                        Text(conversation.note)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(conversation.hasUnreadTextUpdate ? conversation.tone.tint.opacity(0.70) : Palette.panel.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(borderColor, lineWidth: conversation.hasUnreadTextUpdate ? 1.4 : 1)
                    )
                    .shadow(
                        color: conversation.hasUnreadTextUpdate ? conversation.tone.accent.opacity(0.18) : .clear,
                        radius: 18,
                        x: 0,
                        y: 10
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct QuietStatusCard: View {
    var body: some View {
        Text("No active call")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Palette.shellBorder, lineWidth: 1)
                )
        )
    }
}

private struct TranscriptScreen: View {
    let conversation: DemoConversation
    let timeline: [TimelineItem]
    let isCallActive: Bool
    @Binding var isMuted: Bool
    @Binding var speakerEnabled: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TranscriptHeader(
                conversation: conversation,
                isCallActive: isCallActive,
                isMuted: $isMuted,
                speakerEnabled: $speakerEnabled,
                onBack: onBack
            )

            Divider()
                .overlay(Palette.divider)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(timeline) { item in
                            TimelineCard(item: item, accent: conversation.tone.accent)
                                .id(item.id)
                        }
                    }
                    .padding(18)
                }
                .onAppear {
                    scrollToLatest(proxy: proxy)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.11), Color(red: 0.04, green: 0.07, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let last = timeline.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct TranscriptHeader: View {
    let conversation: DemoConversation
    let isCallActive: Bool
    @Binding var isMuted: Bool
    @Binding var speakerEnabled: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Palette.panel)
                        )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.handle)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(isCallActive ? ConversationTone.mint.accent : Palette.textMuted)
                            .frame(width: 6, height: 6)
                        Text(isCallActive ? "on call" : "idle")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isCallActive ? ConversationTone.mint.accent : Palette.textMuted)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    MiniHeaderButton(systemImage: speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        speakerEnabled.toggle()
                    }
                    MiniHeaderButton(systemImage: isMuted ? "mic.slash.fill" : "mic.fill") {
                        isMuted.toggle()
                    }
                    MiniHeaderButton(systemImage: "phone.down.fill", destructive: true) {}
                }
            }

            HStack {
                CapsuleTag(text: conversation.agentName, tone: conversation.tone.accent)
                Text(conversation.shortDirectoryName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(18)
        .background(Palette.panelMuted.opacity(0.97))
    }
}

private struct TimelineCard: View {
    let item: TimelineItem
    let accent: Color

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 46)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(item.body)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(item.timestamp)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.textMuted)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.20, blue: 0.30))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
        case .agent:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                    Text(item.title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                    if let caption = item.caption {
                        Text(caption)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Text(item.body)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(item.timestamp)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Palette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        case .updateCard:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CapsuleTag(text: item.title.lowercased(), tone: accent)
                    Spacer()
                    Text(item.timestamp)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                }

                if let caption = item.caption {
                    Text(caption)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                }

                Text(item.body)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)

                if let codeSnippet = item.codeSnippet {
                    Text(codeSnippet)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.24))
                        )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(accent.opacity(0.48), lineWidth: 1)
                    )
            )
        }
    }
}

private struct SettingsScreen: View {
    let onBack: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text("settings")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    ToolbarButton(
                        label: "back",
                        systemImage: "chevron.left",
                        tone: Palette.panelRaised,
                        action: onBack
                    )
                }

                SettingsSectionCard(title: "Server") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            ServerModeChip(label: "Run on this Mac", isSelected: true)
                            ServerModeChip(label: "Connect remote", isSelected: false)
                        }

                        HStack(alignment: .top, spacing: 16) {
                            QRCodeCard(payload: "tincan://connect?host=wheeljack&port=8004")

                            VStack(alignment: .leading, spacing: 10) {
                                SettingsValueRow(label: "Host", value: "wheeljack")
                                SettingsValueRow(label: "Port", value: "8004")
                                SettingsValueRow(label: "Status", value: "running")
                            }
                        }
                    }
                }

                SettingsSectionCard(title: "Agent backends") {
                    VStack(spacing: 10) {
                        ForEach(Array(SampleData.backendRows.enumerated()), id: \.offset) { _, row in
                            SettingsListRow(primary: row.0, secondary: row.1, trailing: "edit")
                        }
                    }
                }

                SettingsSectionCard(title: "Agent profiles") {
                    VStack(spacing: 10) {
                        ForEach(Array(SampleData.profileRows.enumerated()), id: \.offset) { _, row in
                            SettingsProfileRow(name: row.0, path: row.1, backend: row.2)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.11), Color(red: 0.04, green: 0.07, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
            }

            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Palette.shellBorder, lineWidth: 1)
                )
        )
    }
}

private struct QRCodeCard: View {
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
                                .foregroundStyle(Palette.textMuted)
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
                .foregroundStyle(Palette.textMuted)
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

private struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsListRow: View {
    let primary: String
    let secondary: String
    let trailing: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(primary)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                Text(secondary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Text(trailing)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(ConversationTone.mint.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.panelRaised.opacity(0.72))
        )
    }
}

private struct SettingsProfileRow: View {
    let name: String
    let path: String
    let backend: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ConversationTone.mint.tint)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(name.prefix(2)).uppercased())
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(ConversationTone.mint.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.textPrimary)
                Text(shortDirectoryName(path))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(backend)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(ConversationTone.blue.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.panelRaised.opacity(0.72))
        )
    }
}

private struct ToolbarButton: View {
    let label: String
    let systemImage: String
    let tone: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule(style: .continuous)
                    .fill(tone)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IconToolbarButton: View {
    let systemImage: String
    let tone: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(tone)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MiniControlButton: View {
    let systemImage: String
    let label: String
    let tone: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tone)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Palette.panel)
                            .overlay(
                                Circle()
                                    .stroke(tone.opacity(0.28), lineWidth: 1)
                            )
                    )
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct MiniHeaderButton: View {
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(destructive ? Palette.textPrimary : Palette.textPrimary.opacity(0.88))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(destructive ? Palette.callRed : Palette.panel)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct CapsuleTag: View {
    let text: String
    let tone: Color
    var filled = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(filled ? Color.black.opacity(0.84) : tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? tone : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tone.opacity(filled ? 0 : 0.8), lineWidth: filled ? 0 : 1)
            )
    }
}

private struct ServerModeChip: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(isSelected ? Color.black.opacity(0.82) : Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? ConversationTone.mint.accent : Palette.panelRaised)
            )
    }
}

private struct WaveStrip: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<14, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < 8 ? accent : accent.opacity(0.22))
                    .frame(width: 4, height: waveHeight(at: index))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func waveHeight(at index: Int) -> CGFloat {
        let heights: [CGFloat] = [10, 17, 26, 18, 30, 22, 34, 15, 12, 20, 14, 24, 16, 11]
        return heights[index]
    }
}

private let host = NSHostingController(rootView: DesignPlaygroundView())
host.view.frame = NSRect(x: 0, y: 0, width: 460, height: 940)

#if canImport(PlaygroundSupport)
PlaygroundPage.current.needsIndefiniteExecution = true
PlaygroundPage.current.liveView = host
#endif
