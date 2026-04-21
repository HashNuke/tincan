//
//  tincanTests.swift
//  tincanTests
//
//  Created by Akash Manohar John on 19/04/26.
//

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

}
