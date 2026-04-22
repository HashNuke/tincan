import Combine
import Foundation

struct TincanHighlightedLiveUpdate: Equatable {
    let conversationID: String?
    let title: String
    let body: String
    let timestamp: Date
}

@MainActor
final class TincanWorkspaceStore: ObservableObject {
    enum LiveConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
    }

    @Published private(set) var conversations: [TincanConversationSummary] = []
    @Published private(set) var conversationMessages: [String: [TincanConversationMessage]] = [:]
    @Published private(set) var agentBackends: [TincanAgentBackend] = []
    @Published private(set) var agentProfiles: [TincanAgentProfile] = []
    @Published private(set) var highlightedLiveUpdate: TincanHighlightedLiveUpdate?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingConversationList = false
    @Published private(set) var liveConnectionStatus: LiveConnectionStatus = .idle
    @Published var selectedConversationID: String?

    private let serverSettings: ServerConnectionStore
    private var unreadConversationIDs = Set<String>()
    private var connectionCancellable: AnyCancellable?
    private var liveWebSocketTask: URLSessionWebSocketTask?
    private var liveReceiveTask: Task<Void, Never>?
    private var liveReconnectTask: Task<Void, Never>?
    private var liveConnectionGeneration: UInt64 = 0
    private var hasStarted = false

    init(serverSettings: ServerConnectionStore) {
        self.serverSettings = serverSettings
        connectionCancellable = serverSettings.$connectionRevision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.reloadForConnectionChange()
                }
            }
    }

    deinit {
        liveReconnectTask?.cancel()
        liveReceiveTask?.cancel()
        liveWebSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isLoadingConversationList = true

        Task {
            await reloadForConnectionChange()
        }
    }

    func refreshAll() async {
        await refreshData(resetSelection: false)
    }

    func openConversation(_ conversationID: String) {
        selectedConversationID = conversationID
        markConversationAsRead(conversationID)

        if conversationMessages[conversationID] == nil {
            Task {
                await refreshConversation(conversationID: conversationID)
            }
        }
    }

    func closeConversation() {
        selectedConversationID = nil
    }

    func refreshConversation(conversationID: String) async {
        guard let baseURL = serverSettings.serverBaseURL else {
            return
        }

        let client = TincanAPIClient(baseURL: baseURL)
        do {
            let detail = try await client.listConversationMessages(conversationID: conversationID)
            conversationMessages[conversationID] = deduplicateMessages(detail.messages)
            upsertConversation(detail.conversation)
            markConversationAsRead(conversationID)
        } catch {
            lastSyncError = "Conversation refresh failed: \(error.localizedDescription)"
        }
    }

    func conversation(for id: String) -> TincanConversationSummary? {
        conversations.first(where: { $0.id == id })
    }

    func messages(for conversationID: String) -> [TincanConversationMessage] {
        conversationMessages[conversationID] ?? []
    }

    private func reloadForConnectionChange() async {
        highlightedLiveUpdate = nil
        lastSyncError = nil
        selectedConversationID = nil
        conversationMessages = [:]
        unreadConversationIDs.removeAll()
        stopLiveUpdates()
        isLoadingConversationList = true

        await refreshData(resetSelection: true)
    }

    private func refreshData(resetSelection: Bool) async {
        isLoadingConversationList = conversations.isEmpty
        defer { isLoadingConversationList = false }

        guard let baseURL = serverSettings.serverBaseURL else {
            conversations = []
            agentBackends = []
            agentProfiles = []
            lastSyncError = "Connection target is incomplete."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let client = TincanAPIClient(baseURL: baseURL)
        var failures: [String] = []

        do {
            conversations = try await client.listConversations()
        } catch {
            conversations = []
            failures.append("Conversations: \(error.localizedDescription)")
        }

        do {
            agentBackends = try await client.listAgentBackends()
        } catch {
            agentBackends = []
            failures.append("Backends: \(error.localizedDescription)")
        }

        do {
            agentProfiles = try await client.listAgentProfiles()
        } catch {
            agentProfiles = []
            failures.append("Profiles: \(error.localizedDescription)")
        }

        if resetSelection, let selectedConversationID, conversations.contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = selectedConversationID
        }

        applyPresentationFlags()
        lastRefreshAt = Date()
        lastSyncError = failures.isEmpty ? nil : failures.joined(separator: "\n")

        await serverSettings.refreshHealth()
        restartLiveUpdates()
    }

    private func restartLiveUpdates() {
        stopLiveUpdates()

        guard let liveURL = serverSettings.liveUpdatesURL else {
            liveConnectionStatus = .disconnected("Live updates URL is unavailable.")
            return
        }

        liveConnectionStatus = .connecting

        let task = URLSession.shared.webSocketTask(with: liveURL)
        liveWebSocketTask = task
        task.resume()

        let generation = liveConnectionGeneration
        liveReceiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    if liveConnectionStatus != .connected {
                        liveConnectionStatus = .connected
                    }

                    switch message {
                    case .string(let payload):
                        try handleLivePayload(Data(payload.utf8))
                    case .data(let payload):
                        try handleLivePayload(payload)
                    @unknown default:
                        break
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                liveConnectionStatus = .disconnected(error.localizedDescription)
                scheduleLiveReconnect(after: 2, generation: generation)
            }
        }
    }

    private func stopLiveUpdates() {
        liveConnectionGeneration &+= 1
        liveReconnectTask?.cancel()
        liveReconnectTask = nil

        liveReceiveTask?.cancel()
        liveReceiveTask = nil

        if let liveWebSocketTask {
            liveWebSocketTask.cancel(with: .goingAway, reason: nil)
        }
        liveWebSocketTask = nil
        liveConnectionStatus = .idle
    }

    private func scheduleLiveReconnect(after delaySeconds: TimeInterval, generation: UInt64) {
        liveReconnectTask?.cancel()
        liveReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delayNanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            guard generation == liveConnectionGeneration else { return }
            restartLiveUpdates()
        }
    }

    private func handleLivePayload(_ data: Data) throws {
        let envelope = try LiveEnvelope.decode(from: data)

        switch envelope {
        case .snapshot(let snapshot):
            updateActiveConversation(hasActiveCall: snapshot.hasActiveCall, conversationID: snapshot.activeConversationID)
        case .activeConversationChanged(let event):
            updateActiveConversation(hasActiveCall: event.hasActiveCall, conversationID: event.activeConversationID)
        case .conversationSummaryUpdated(let event):
            upsertConversation(event.conversation.uiModel)
        case .conversationMessageCreated(let event):
            let message = event.message.uiModel
            var existing = conversationMessages[event.conversationID] ?? []
            if !existing.contains(where: { $0.id == message.id }) {
                existing.insert(message, at: 0)
                conversationMessages[event.conversationID] = deduplicateMessages(existing)
            }

            if selectedConversationID != event.conversationID {
                unreadConversationIDs.insert(event.conversationID)
            }

            if let conversation = conversation(for: event.conversationID) {
                var updatedConversation = conversation
                updatedConversation.hasPendingUpdate = updatedConversation.hasPendingUpdate || message.status == "pending"
                updatedConversation = withPreview(
                    updatedConversation,
                    preview: message.summaryText,
                    updatedAt: message.updatedAt
                )
                upsertConversation(updatedConversation)
            }

            highlightedLiveUpdate = TincanHighlightedLiveUpdate(
                conversationID: event.conversationID,
                title: "update",
                body: message.summaryText.isEmpty ? message.detailText : message.summaryText,
                timestamp: message.updatedAt
            )
        case .textEvent(let event):
            highlightedLiveUpdate = TincanHighlightedLiveUpdate(
                conversationID: event.conversationID,
                title: event.event.kind.replacingOccurrences(of: "_", with: " "),
                body: event.event.summaryText.isEmpty ? event.event.text : event.event.summaryText,
                timestamp: Date()
            )
        }
    }

    private func updateActiveConversation(hasActiveCall: Bool, conversationID: String?) {
        let activeConversationID = hasActiveCall ? conversationID : nil
        conversations = conversations.map { conversation in
            var updatedConversation = conversation
            updatedConversation.isCurrentCallConversation = updatedConversation.id == activeConversationID
            return updatedConversation
        }
    }

    private func applyPresentationFlags() {
        conversations = conversations.map { conversation in
            var updatedConversation = conversation
            updatedConversation.hasUnreadTextUpdate = unreadConversationIDs.contains(conversation.id)
            return updatedConversation
        }
        sortConversations()
    }

    private func upsertConversation(_ conversation: TincanConversationSummary) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            var updatedConversation = conversation
            updatedConversation.hasUnreadTextUpdate = unreadConversationIDs.contains(conversation.id)
            updatedConversation.isCurrentCallConversation = conversations[index].isCurrentCallConversation
            conversations[index] = updatedConversation
        } else {
            var updatedConversation = conversation
            updatedConversation.hasUnreadTextUpdate = unreadConversationIDs.contains(conversation.id)
            conversations.append(updatedConversation)
        }

        sortConversations()
    }

    private func withPreview(
        _ conversation: TincanConversationSummary,
        preview: String,
        updatedAt: Date
    ) -> TincanConversationSummary {
        var updatedConversation = conversation
        if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedConversation = TincanConversationSummary(
                id: conversation.id,
                handle: conversation.handle,
                agentProfileName: conversation.agentProfileName,
                agentBackend: conversation.agentBackend,
                workingDirectory: conversation.workingDirectory,
                status: conversation.status,
                updatedAt: updatedAt,
                previewText: preview,
                hasPendingUpdate: conversation.hasPendingUpdate,
                hasUnreadTextUpdate: conversation.hasUnreadTextUpdate,
                isCurrentCallConversation: conversation.isCurrentCallConversation
            )
        }
        return updatedConversation
    }

    private func markConversationAsRead(_ conversationID: String) {
        unreadConversationIDs.remove(conversationID)
        applyPresentationFlags()
    }

    private func sortConversations() {
        conversations.sort { lhs, rhs in
            if lhs.isCurrentCallConversation != rhs.isCurrentCallConversation {
                return lhs.isCurrentCallConversation && !rhs.isCurrentCallConversation
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func deduplicateMessages(_ messages: [TincanConversationMessage]) -> [TincanConversationMessage] {
        var seen = Set<String>()
        var result: [TincanConversationMessage] = []

        for message in messages {
            if seen.insert(message.id).inserted {
                result.append(message)
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id > rhs.id
        }
    }
}

private struct LiveSnapshotEvent: Decodable {
    let type: String
    let hasActiveCall: Bool
    let activeConversationID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case hasActiveCall = "has_active_call"
        case activeConversationID = "active_conversation_id"
    }
}

private struct LiveActiveConversationEvent: Decodable {
    let type: String
    let hasActiveCall: Bool
    let activeConversationID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case hasActiveCall = "has_active_call"
        case activeConversationID = "active_conversation_id"
    }
}

private struct LiveConversationSummaryEvent: Decodable {
    let type: String
    let conversation: LiveConversationSummaryDTO
}

private struct LiveConversationSummaryDTO: Decodable {
    let id: String
    let handle: String
    let agentProfileName: String
    let agentBackend: String
    let workingDirectory: String
    let status: String
    let updatedAt: Date
    let previewText: String
    let hasPendingUpdate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case handle
        case agentProfileName = "agent_profile_name"
        case agentBackend = "agent_backend"
        case workingDirectory = "working_directory"
        case status
        case updatedAt = "updated_at"
        case previewText = "preview_text"
        case hasPendingUpdate = "has_pending_update"
    }

    var uiModel: TincanConversationSummary {
        TincanConversationSummary(
            id: id,
            handle: handle,
            agentProfileName: agentProfileName,
            agentBackend: agentBackend,
            workingDirectory: workingDirectory,
            status: status,
            updatedAt: updatedAt,
            previewText: previewText,
            hasPendingUpdate: hasPendingUpdate,
            hasUnreadTextUpdate: false,
            isCurrentCallConversation: false
        )
    }
}

private struct LiveConversationMessageEvent: Decodable {
    let type: String
    let conversationID: String
    let message: LiveConversationMessageDTO

    enum CodingKeys: String, CodingKey {
        case type
        case conversationID = "conversation_id"
        case message
    }
}

private struct LiveConversationMessageDTO: Decodable {
    let id: String
    let kind: String
    let summaryText: String
    let detailText: String
    let notificationText: String
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let consumedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case summaryText = "summary_text"
        case detailText = "detail_text"
        case notificationText = "notification_text"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case consumedAt = "consumed_at"
    }

    var uiModel: TincanConversationMessage {
        TincanConversationMessage(
            id: id,
            kind: kind,
            summaryText: summaryText,
            detailText: detailText,
            notificationText: notificationText,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            consumedAt: consumedAt
        )
    }
}

private struct LiveTextEvent: Decodable {
    struct EventPayload: Decodable {
        let kind: String
        let text: String
        let summaryText: String

        enum CodingKeys: String, CodingKey {
            case kind
            case text
            case summaryText = "summary_text"
        }
    }

    let type: String
    let conversationID: String?
    let event: EventPayload

    enum CodingKeys: String, CodingKey {
        case type
        case conversationID = "conversation_id"
        case event
    }
}

private enum LiveEnvelope {
    case snapshot(LiveSnapshotEvent)
    case activeConversationChanged(LiveActiveConversationEvent)
    case conversationSummaryUpdated(LiveConversationSummaryEvent)
    case conversationMessageCreated(LiveConversationMessageEvent)
    case textEvent(LiveTextEvent)

    private struct TypeEnvelope: Decodable {
        let type: String
    }

    static func decode(from data: Data) throws -> LiveEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = TincanWorkspaceDateDecoders.fractional.date(from: value) ??
                TincanWorkspaceDateDecoders.basic.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date value: \(value)"
            )
        }

        let typeEnvelope = try decoder.decode(TypeEnvelope.self, from: data)
        switch typeEnvelope.type {
        case "snapshot":
            return .snapshot(try decoder.decode(LiveSnapshotEvent.self, from: data))
        case "active_conversation_changed":
            return .activeConversationChanged(try decoder.decode(LiveActiveConversationEvent.self, from: data))
        case "conversation_summary_updated":
            return .conversationSummaryUpdated(try decoder.decode(LiveConversationSummaryEvent.self, from: data))
        case "conversation_message_created":
            return .conversationMessageCreated(try decoder.decode(LiveConversationMessageEvent.self, from: data))
        case "text_event":
            return .textEvent(try decoder.decode(LiveTextEvent.self, from: data))
        default:
            throw URLError(.cannotParseResponse)
        }
    }
}

private enum TincanWorkspaceDateDecoders {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
