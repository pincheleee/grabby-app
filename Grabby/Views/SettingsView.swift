import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var prefs: PreferencesStore
    @State private var updateMessage = ""

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

            Section("Maintenance") {
                HStack {
                    Text("yt-dlp")
                    Spacer()
                    if updateMessage.isEmpty {
                        Button("Check for Updates") {
                            Task {
                                updateMessage = "Checking..."
                                updateMessage = await YTDLPService.shared.updateYTDLP()
                                try? await Task.sleep(for: .seconds(3))
                                updateMessage = ""
                            }
                        }
                    } else {
                        Text(updateMessage)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .onChange(of: prefs.format) { _, _ in prefs.save() }
        .onChange(of: prefs.quality) { _, _ in prefs.save() }
        .onChange(of: prefs.audioFormat) { _, _ in prefs.save() }
        .onChange(of: prefs.cookieBrowser) { _, _ in prefs.save() }
        .onChange(of: prefs.downloadDir) { _, _ in prefs.save() }
    }
}
