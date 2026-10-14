import AppKit
import PhotosBackupCore
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var usage: StorageUsage?
    @State private var cleaning = false
    @State private var freed: Int64?
    @State private var copied = false

    private static let gpmc = URL(string: "https://github.com/xob0t/gpmc")!
    private static let gotohp = URL(string: "https://github.com/xob0t/gotohp")!

    var body: some View {
        Form {
            Section {
                if let usage {
                    LabeledContent("Upload copies", value: usage.staging.byteString)
                    LabeledContent("Logs", value: usage.logs.byteString)
                    LabeledContent("Backup history", value: usage.state.byteString)
                    LabeledContent("Run history and timeline", value: usage.history.byteString)
                    LabeledContent("Total") {
                        HStack(spacing: 10) {
                            Text(usage.total.byteString).fontWeight(.medium)
                            Button("Clean Up") { cleanUp() }
                                .disabled(cleaning || model.engine.isActive || model.archive.isRunning)
                        }
                    }
                    if let freed {
                        Text(freed > 0 ? "Freed \(freed.byteString)." : "Nothing needed cleaning up.").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text("Storage")
            } footer: {
                FormNote("Upload copies are made from Photos for each batch and removed after it; Clean Up removes any a crash left behind, and old logs.")
            }

            Section {
                HStack {
                    Button("Export Report…", action: exportReport)
                    Button(copied ? "Copied" : "Copy Report", action: copyReport)
                    Spacer()
                    Button("Show Logs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.bridgeLog]) }
                    Button("View Timeline") { AppRouter.shared.openMain(section: .activity) }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                FormNote("The report lists versions, settings, recent runs and problems, with account addresses, file names and tokens removed, so it is safe to attach to a bug report.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Uploader", value: model.runtimeDescription)
                LabeledContent("Upload engine") {
                    Link("gpmc by xob0t", destination: Self.gpmc)
                }
                LabeledContent("Sign-in flow") {
                    Link("gotohp by xob0t", destination: Self.gotohp)
                }
                FormNote("Photos Backup is not made by Google. It talks to Google Photos' unofficial mobile interface, as an Android phone would. Google can change or end that at any time; uploads would then count against your storage or stop, and nothing in Photos is touched either way.")
            } header: {
                Text("About")
            }
        }
        .settingsForm(height: 660)
        .task { usage = await model.diagnostics.usage() }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development build"
        let build = info?["CFBundleVersion"] as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }

    private func cleanUp() {
        cleaning = true
        Task {
            freed = await model.diagnostics.cleanUp()
            usage = await model.diagnostics.usage()
            cleaning = false
        }
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Photos Backup Report \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let report = model.diagnostics.report(model: model)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics.report(model: model), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
