//
//  tincanTests.swift
//  tincanTests
//
//  Created by Akash Manohar John on 19/04/26.
//

import Testing
@testable import tincan

struct tincanTests {

    @Test func notificationPlaybackUsesDetailWhenIdle() {
        let choice = BackendSessionClient.notificationPlaybackChoice(
            text: "emma#14 has an update.",
            audioURLPath: "/debug/audio/generated/short.wav",
            detailText: "The build finished and all tests passed.",
            detailAudioURLPath: "/debug/audio/generated/detail.wav",
            isAudioPlaying: false
        )

        #expect(choice.text == "The build finished and all tests passed.")
        #expect(choice.audioURLPath == "/debug/audio/generated/detail.wav")
    }

    @Test func notificationPlaybackKeepsShortPromptDuringActivePlayback() {
        let choice = BackendSessionClient.notificationPlaybackChoice(
            text: "emma#14 has an update.",
            audioURLPath: "/debug/audio/generated/short.wav",
            detailText: "The build finished and all tests passed.",
            detailAudioURLPath: "/debug/audio/generated/detail.wav",
            isAudioPlaying: true
        )

        #expect(choice.text == "emma#14 has an update.")
        #expect(choice.audioURLPath == "/debug/audio/generated/short.wav")
    }

}
