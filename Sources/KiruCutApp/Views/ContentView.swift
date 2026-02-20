import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CutterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Files") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Select Input") {
                            viewModel.pickInputFile()
                        }
                        .frame(width: 110, alignment: .leading)
                        Text(viewModel.inputPathDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    HStack {
                        Button("Select Output") {
                            viewModel.pickOutputFile()
                        }
                        .frame(width: 110, alignment: .leading)
                        Text(viewModel.outputPathDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Trim") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Start Time (seconds)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.hasSelectedInput {
                            TextField("", text: $viewModel.startTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        } else {
                            TextField("", text: $viewModel.startTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .disabled(true)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("End Time (seconds or mm:ss)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.hasSelectedInput {
                            TextField("", text: $viewModel.endTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        } else {
                            TextField("", text: $viewModel.endTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .disabled(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("Cut Video") {
                    viewModel.runCut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isRunning)
            }

            ProgressView(value: viewModel.progressValue, total: 1.0)
                .progressViewStyle(.linear)
                .opacity(viewModel.isRunning || viewModel.progressValue > 0 ? 1 : 0)

            Text(viewModel.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(viewModel.statusColor)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(20)
    }
}
