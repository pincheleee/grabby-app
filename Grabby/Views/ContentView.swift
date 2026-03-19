import SwiftUI

enum AppTab: String, CaseIterable {
    case download = "Download"
    case queue = "Queue"
    case history = "History"
}

struct ContentView: View {
    @EnvironmentObject var dm: DownloadManager
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var prefs: PreferencesStore

    @State private var selectedTab: AppTab = .download
    @State private var urlText = ""
    @State private var selectedFormat: DownloadFormat = .mp4
    @State private var selectedQuality: VideoQuality = .best
    @State private var showingDone = false
    @State private var lastDoneJob: DownloadJob?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("Grabby")
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "ff5c39"), Color(hex: "ff8c39")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("GRAB WHAT YOU NEED")
                    .font(.system(size: 12, weight: .light))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Tabs
            Picker("", selection: $selectedTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Content
            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .download:
                        downloadView
                    case .queue:
                        queueView
                    case .history:
                        historyView
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            // Footer
            HStack(spacing: 4) {
                Button(prefs.downloadDir.hasSuffix("Downloads/Grabby") ? "~/Downloads/Grabby" : (prefs.downloadDir as NSString).lastPathComponent) {
                    dm.openDownloadFolder(path: prefs.downloadDir)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: "ff5c39"))
                .font(.system(size: 12))

                Text("  ·  Powered by yt-dlp  ·  v2.0.0")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: dm.pendingURL) { _, url in
            if !url.isEmpty {
                urlText = url
                dm.pendingURL = ""
                fetchInfo()
            }
        }
        .onAppear {
            selectedFormat = prefs.format
            selectedQuality = prefs.quality
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .sheet(isPresented: $showingDone) {
            doneSheet
        }
    }

    // MARK: - Download Tab

    private var downloadView: some View {
        VStack(spacing: 16) {
            // URL input
            HStack(spacing: 10) {
                TextField("Paste a YouTube URL...", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { fetchInfo() }

                Button(action: fetchInfo) {
                    if dm.isFetching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Text("Preview")
                            .frame(width: 60)
                    }
                }
                .disabled(dm.isFetching || urlText.isEmpty)
            }

            // Error
            if let error = dm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .textSelection(.enabled)
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Preview
            if let info = dm.currentInfo {
                PreviewCard(info: info)
            }

            // Playlist
            if dm.isPlaylist {
                PlaylistView(entries: $dm.playlistEntries)
            }

            // Options
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FORMAT")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .tracking(1.5)

                        Picker("Format", selection: $selectedFormat) {
                            Section("Video") {
                                ForEach(DownloadFormat.videoFormats) { fmt in
                                    Text(fmt.label).tag(fmt)
                                }
                            }
                            Section("Audio Only") {
                                ForEach(DownloadFormat.audioFormats) { fmt in
                                    Text(fmt.label).tag(fmt)
                                }
                            }
                        }
                        .labelsHidden()
                    }

                    if !selectedFormat.isAudio {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("QUALITY")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .tracking(1.5)

                            Picker("Quality", selection: $selectedQuality) {
                                ForEach(VideoQuality.allCases) { q in
                                    Text(q.label).tag(q)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COOKIES FROM")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .tracking(1.5)

                        Picker("Cookies", selection: $prefs.cookieBrowser) {
                            Text("None").tag("")
                            Text("Safari").tag("safari")
                            Text("Chrome").tag("chrome")
                            Text("Firefox").tag("firefox")
                            Text("Brave").tag("brave")
                        }
                        .labelsHidden()
                        .onChange(of: prefs.cookieBrowser) { _, _ in prefs.save() }
                    }
                    Spacer()
                }
            }

            // Download button
            Button(action: startDownload) {
                HStack {
                    if dm.jobs.first(where: { $0.status == .downloading }) != nil && !dm.isPlaylist {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(dm.isPlaylist ? "Download Selected" : "Download")
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "ff5c39"))
            .disabled(urlText.isEmpty)

            // Active download progress
            ForEach(dm.jobs.prefix(3).filter { $0.status == .downloading }) { job in
                ProgressCard(job: job) {
                    dm.cancelJob(job)
                }
            }
        }
    }

    // MARK: - Queue Tab

    private var queueView: some View {
        VStack(spacing: 12) {
            if dm.jobs.isEmpty {
                emptyState(icon: "arrow.down.circle", title: "No active downloads",
                          subtitle: "Start a download and it will appear here")
            } else {
                ForEach(dm.jobs) { job in
                    QueueItemCard(job: job, onCancel: { dm.cancelJob(job) },
                                  onReveal: { dm.revealInFinder(job) })
                }
            }
        }
    }

    // MARK: - History Tab

    private var historyView: some View {
        VStack(spacing: 12) {
            if history.items.isEmpty {
                emptyState(icon: "clock", title: "No downloads yet",
                          subtitle: "Your download history will appear here")
            } else {
                HStack {
                    Spacer()
                    Button("Clear All") {
                        history.clearAll()
                    }
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                }

                ForEach(history.items) { item in
                    HistoryItemRow(item: item)
                }
            }
        }
        .onAppear { history.load() }
    }

    // MARK: - Done Sheet

    private var doneSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Download Complete")
                .font(.system(size: 18, weight: .semibold))

            if let job = lastDoneJob {
                Text((job.filename as NSString).lastPathComponent)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    if let job = lastDoneJob { dm.revealInFinder(job) }
                    showingDone = false
                }

                Button("New Download") {
                    showingDone = false
                    dm.reset()
                    urlText = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "ff5c39"))
            }
        }
        .padding(32)
        .frame(width: 400)
    }

    // MARK: - Helpers

    private func fetchInfo() {
        guard !urlText.isEmpty else { return }
        Task {
            await dm.fetchInfo(url: urlText, cookieBrowser: prefs.cookieBrowser)
        }
    }

    private func startDownload() {
        guard !urlText.isEmpty else { return }

        if dm.isPlaylist {
            dm.startPlaylistDownload(
                entries: dm.playlistEntries,
                format: selectedFormat, quality: selectedQuality,
                cookieBrowser: prefs.cookieBrowser, downloadDir: prefs.downloadDir
            )
            selectedTab = .queue
        } else {
            dm.startDownload(
                url: urlText,
                title: dm.currentInfo?.title ?? "",
                thumbnail: dm.currentInfo?.thumbnail ?? "",
                format: selectedFormat, quality: selectedQuality,
                cookieBrowser: prefs.cookieBrowser, downloadDir: prefs.downloadDir
            )
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

import UserNotifications
