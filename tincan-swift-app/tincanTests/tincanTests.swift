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

    @Test func notificationPlaybackUsesSummaryWhenIdle() {
        let choice = BackendSessionClient.notificationPlaybackChoice(
            text: "I have an update.",
            audioURLPath: "/debug/audio/generated/short.wav",
            summaryText: "I finished the build work and all tests passed.",
            summaryAudioURLPath: "/debug/audio/generated/summary.wav",
            isAudioPlaying: false
        )

        #expect(choice.text == "I finished the build work and all tests passed.")
        #expect(choice.audioURLPath == "/debug/audio/generated/summary.wav")
    }

    @Test func notificationPlaybackKeepsShortPromptDuringActivePlayback() {
        let choice = BackendSessionClient.notificationPlaybackChoice(
            text: "I have an update.",
            audioURLPath: "/debug/audio/generated/short.wav",
            summaryText: "I finished the build work and all tests passed.",
            summaryAudioURLPath: "/debug/audio/generated/summary.wav",
            isAudioPlaying: true
        )

        #expect(choice.text == "I have an update.")
        #expect(choice.audioURLPath == "/debug/audio/generated/short.wav")
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

}
