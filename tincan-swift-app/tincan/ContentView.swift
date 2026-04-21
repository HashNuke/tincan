import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: TincanAppModel

    var body: some View {
#if os(iOS)
        IOSCallView(viewModel: appModel.callSession)
#elseif os(macOS)
        MacCallView(callSession: appModel.macCallSession)
#else
        Text("tincan is currently configured for iOS and macOS.")
            .padding()
#endif
    }
}

#if os(iOS)
private struct IOSCallView: View {
    @ObservedObject var viewModel: CallSessionViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backend URL")
                            .font(.headline)
                        TextField(BackendConnectionConfig.serverBaseURLString, text: $viewModel.backendURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        Text("Enter the tincan server base URL, e.g. `\(BackendConnectionConfig.serverBaseURLString)`. `localhost` only works on the same machine.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Call Status")
                            .font(.headline)
                        Text(viewModel.callStateDescription)
                            .font(.title3.weight(.semibold))
                        if !viewModel.lastServerTranscript.isEmpty {
                            Text("Last Transcript")
                                .font(.headline)
                                .padding(.top, 8)
                            Text(viewModel.lastServerTranscript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Start Call") {
                            viewModel.startCall()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isCallActive)

                        Button("End Call") {
                            viewModel.endCall()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.isCallActive)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Activity")
                            .font(.headline)
                        if viewModel.logLines.isEmpty {
                            Text("No activity yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(.footnote.monospaced())
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("tincan")
        }
    }
}
#endif

#if os(macOS)
private struct MacCallView: View {
    @ObservedObject var callSession: MacCallSessionViewModel

    private var callSummary: String {
        if callSession.isCallActive {
            return "The mic is live and tincan is routing your speech to the backend."
        }

        return "Start a call when you're ready to talk to your coding agent."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("tincan")
                    .font(.largeTitle.weight(.bold))

                Text("Call into your coding agent from this Mac.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Call")
                    .font(.headline)

                Text(callSession.callStateDescription)
                    .font(.title2.weight(.semibold))

                Text(callSummary)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Start Call") {
                        callSession.startCall()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(callSession.isCallActive)

                    Button("End Call") {
                        callSession.endCall()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!callSession.isCallActive)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text("Speaker")
                    .font(.headline)

                Text(callSession.identityStatusDescription)
                    .font(.title3.weight(.semibold))

                Text(callSession.ownerProfileDescription)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Identify Speaker") {
                        callSession.beginSpeakerIdentification()
                    }
                    .disabled(!callSession.isCallActive)

                    Button("Reset Voice") {
                        callSession.resetSpeakerProfile()
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

            if !callSession.lastServerTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Last Transcript")
                        .font(.headline)

                    Text(callSession.lastServerTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 320)
    }
}
#endif
