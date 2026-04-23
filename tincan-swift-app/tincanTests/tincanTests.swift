//
//  tincanTests.swift
//  tincanTests
//
//  Created by Akash Manohar John on 19/04/26.
//

import Foundation
import Testing
@testable import tincan

struct tincanTests {

    @Test func notificationDisplayPrefersSummaryText() {
        let text = BackendSessionClient.notificationDisplayText(
            text: "I have an update.",
            summaryText: "I finished the build work and all tests passed."
        )

        #expect(text == "I finished the build work and all tests passed.")
    }

    @Test func notificationDisplayFallsBackToPrimaryText() {
        let text = BackendSessionClient.notificationDisplayText(
            text: "I have an update.",
            summaryText: "   "
        )

        #expect(text == "I have an update.")
    }

    @Test func responseBodySummaryTrimsWhitespaceAndCollapsesLines() {
        let summary = BackendSessionClient.responseBodySummary(
            from: Data(" \nset remote description: missing ICE credentials\n ".utf8)
        )

        #expect(summary == "set remote description: missing ICE credentials")
    }

    @Test func validatedSessionDescriptionPreservesTerminalCRLF() {
        let rawSDP = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"

        let validated = BackendSessionClient.validatedSessionDescriptionSDP(rawSDP)

        #expect(validated == rawSDP)
        #expect(validated?.hasSuffix("\r\n") == true)
    }

    @Test func validatedSessionDescriptionRejectsWhitespaceOnlyPayload() {
        let validated = BackendSessionClient.validatedSessionDescriptionSDP(" \n\r\t ")

        #expect(validated == nil)
    }

    @Test func conversationAgentProcessStatusTreatsBusyLifecycleStatesAsRunning() {
        let conversation = TincanConversationSummary(
            id: "conv-1",
            handle: "Emma#1",
            agentProfileName: "Emma",
            agentBackend: "opencode",
            workingDirectory: "/Users/akash/code/apple/tincan",
            status: "busy",
            updatedAt: .now,
            previewText: "",
            hasPendingUpdate: false,
            hasUnreadTextUpdate: false,
            isCurrentCallConversation: false
        )

        #expect(conversation.agentProcessStatus == .running)
        #expect(TincanAgentProcessStatus(conversationStatus: "starting") == .running)
        #expect(TincanAgentProcessStatus(conversationStatus: "retry") == .running)
    }

    @Test func conversationAgentProcessStatusTreatsCompletedAndFailedStatesAsIdle() {
        let conversation = TincanConversationSummary(
            id: "conv-2",
            handle: "Emma#2",
            agentProfileName: "Emma",
            agentBackend: "opencode",
            workingDirectory: "/Users/akash/code/apple/tincan",
            status: "running",
            updatedAt: .now,
            previewText: "",
            hasPendingUpdate: false,
            hasUnreadTextUpdate: false,
            isCurrentCallConversation: false
        )

        #expect(conversation.agentProcessStatus == .idle)
        #expect(TincanAgentProcessStatus(conversationStatus: "failed") == .idle)
        #expect(TincanAgentProcessStatus(conversationStatus: "aborted") == .idle)
    }

    @Test func callDurationLabelShowsPlaceholderBeforeTimerStarts() {
        #expect(callDurationLabel(startedAt: nil, isCallActive: false, isTransitioning: false) == nil)
        #expect(callDurationLabel(startedAt: nil, isCallActive: false, isTransitioning: true) == "--:--:--")
        #expect(callDurationLabel(startedAt: nil, isCallActive: true, isTransitioning: true) == "--:--:--")
    }

    @Test func callDurationLabelShowsElapsedTimeAfterTimerStarts() {
        let startedAt = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 3_735)

        #expect(
            callDurationLabel(
                startedAt: startedAt,
                isCallActive: true,
                isTransitioning: false,
                now: now
            ) == "01:02:05"
        )
    }

}
