import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: TincanAppModel

    var body: some View {
#if os(iOS)
        IOSCallView(viewModel: appModel.callSession)
#elseif os(macOS)
        MacBackendView(controller: appModel.backendHost, callSession: appModel.macCallSession)
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
                        TextField(BackendConnectionConfig.inferenceURLString, text: $viewModel.backendURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        Text("Device builds should use `\(BackendConnectionConfig.inferenceURLString)`. `localhost` only works on the same machine.")
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
private struct MacBackendView: View {
    @ObservedObject var controller: BackendServerController
    @ObservedObject var callSession: MacCallSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local Backend")
                .font(.largeTitle.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Local Call")
                    .font(.headline)
                Text(callSession.callStateDescription)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 12) {
                    Button("Call") {
                        callSession.startCall()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(callSession.isCallActive)

                    Button("Disconnect") {
                        callSession.endCall()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!callSession.isCallActive)
                }

                if !callSession.lastServerTranscript.isEmpty {
                    Text("Latest Local Transcript")
                        .font(.headline)
                        .padding(.top, 4)
                    Text(callSession.lastServerTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Text(controller.statusDescription)
                .font(.title3.weight(.semibold))

            if let primaryEndpoint = controller.primaryEndpoint {
                LabeledContent("Primary Endpoint") {
                    Text(primaryEndpoint)
                        .textSelection(.enabled)
                }
            }

            if !controller.availableEndpoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reachable Endpoints")
                        .font(.headline)
                    ForEach(controller.availableEndpoints, id: \.self) { endpoint in
                        Text(endpoint)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Restart Backend") {
                    controller.restart()
                }
                Button("Stop Backend") {
                    controller.stop()
                }
            }

            Divider()

            Text("Live Transcripts")
                .font(.headline)
            if controller.recentTranscripts.isEmpty {
                Text("Speech from the phone will appear here once the backend receives a turn.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(controller.recentTranscripts.enumerated()), id: \.offset) { _, transcript in
                            Text(transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 240)
            }

            Divider()

            Text("Backend Logs")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Text("Call Activity")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if callSession.logLines.isEmpty {
                        Text("No call activity yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(callSession.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 620)
    }
}
#endif
