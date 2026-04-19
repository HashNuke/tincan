import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: TincanAppModel

    var body: some View {
#if os(iOS)
        IOSCallView(viewModel: appModel.callSession)
#elseif os(macOS)
        MacBackendView(controller: appModel.backendHost)
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
                        TextField("http://192.168.1.10:52734/infer", text: $viewModel.backendURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        Text("Use `http://127.0.0.1:52734/infer` on Simulator, or your Mac's LAN IP on a device.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local Backend")
                .font(.largeTitle.weight(.bold))

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
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
    }
}
#endif
