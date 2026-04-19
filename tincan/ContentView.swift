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
        VStack(alignment: .leading, spacing: 18) {
            Text("tincan")
                .font(.largeTitle.weight(.bold))

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

                Spacer()

                Text(callSession.callStateDescription)
                    .font(.title3.weight(.semibold))
            }

            if let latestCallLog = callSession.logLines.first {
                Text(latestCallLog)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Server Diagnostics")
                    .font(.headline)

                Text(controller.statusDescription)
                    .font(.title3.weight(.semibold))

                if let primaryEndpoint = controller.primaryEndpoint {
                    LabeledContent("Endpoint") {
                        Text(primaryEndpoint)
                            .textSelection(.enabled)
                            .font(.footnote.monospaced())
                    }
                }

                HStack(spacing: 12) {
                    Button("Refresh") {
                        controller.refresh()
                    }

                    Text(controller.loopbackHealthEndpoint)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let latestLog = controller.logLines.first {
                    Text(latestLog)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 220)
    }
}
#endif
