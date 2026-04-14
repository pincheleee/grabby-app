import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var prefs: PreferencesStore
    @State private var updateMessage = ""
    @State private var dependencyStatus: DependencyStatus?
    @State private var isRefreshingDependencies = false
    @State private var isUpdatingYTDLP = false

    private var updateButtonTitle: String {
        switch dependencyStatus?.ytdlp.source {
        case .bundled:
            return "Install Managed Copy"
        case .managed:
            return "Check for Updates"
        default:
            return "Check for Updates"
        }
    }

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Video Format", selection: $prefs.format) {
                    ForEach(DownloadFormat.videoFormats) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }

                Picker("Quality", selection: $prefs.quality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }

                Picker("Audio Format", selection: $prefs.audioFormat) {
                    ForEach(DownloadFormat.audioFormats) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }

                Picker("Cookie Browser", selection: $prefs.cookieBrowser) {
                    Text("None").tag("")
                    Text("Safari (requires Full Disk Access)").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("Brave").tag("brave")
                }
            }

            Section("Storage") {
                HStack {
                    TextField("Download Folder", text: $prefs.downloadDir)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            prefs.downloadDir = url.path
                        }
                    }
                }
            }

            Section("Dependencies") {
                if isRefreshingDependencies && dependencyStatus == nil {
                    ProgressView("Checking dependencies...")
                } else if let dependencyStatus {
                    dependencyRow(title: "yt-dlp", status: dependencyStatus.ytdlp)
                    dependencyRow(title: "ffmpeg", status: dependencyStatus.ffmpeg)
                } else {
                    Text("Dependency status unavailable.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Maintenance") {
                Text("Grabby installs yt-dlp updates into `~/Library/Application Support/Grabby/bin` so the signed app bundle stays untouched.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("yt-dlp")
                    Spacer()
                    if isUpdatingYTDLP {
                        ProgressView()
                    } else {
                        Button(updateButtonTitle) {
                            Task { await updateYTDLP() }
                        }
                    }
                }

                if !updateMessage.isEmpty {
                    Text(updateMessage)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }

                HStack {
                    Text("Dependency Health")
                    Spacer()
                    if isRefreshingDependencies {
                        ProgressView()
                    } else {
                        Button("Refresh Status") {
                            Task { await refreshDependencyStatus() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .task {
            await refreshDependencyStatus()
        }
        .onChange(of: prefs.format) { _, _ in prefs.save() }
        .onChange(of: prefs.quality) { _, _ in prefs.save() }
        .onChange(of: prefs.audioFormat) { _, _ in prefs.save() }
        .onChange(of: prefs.cookieBrowser) { _, _ in prefs.save() }
        .onChange(of: prefs.downloadDir) { _, _ in prefs.save() }
    }

    private func dependencyRow(title: String, status: BinaryStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(status.source.label)
                    .foregroundStyle(status.isAvailable ? Color.secondary : Color.red)
                    .font(.system(size: 12, weight: .medium))
            }

            Text(status.pathLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(status.isAvailable ? Color.secondary : Color.red)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func refreshDependencyStatus() async {
        isRefreshingDependencies = true
        dependencyStatus = await YTDLPService.shared.dependencyStatus()
        isRefreshingDependencies = false
    }

    private func updateYTDLP() async {
        isUpdatingYTDLP = true
        updateMessage = "Checking..."
        updateMessage = await YTDLPService.shared.updateYTDLP()
        await refreshDependencyStatus()
        isUpdatingYTDLP = false
    }
}
