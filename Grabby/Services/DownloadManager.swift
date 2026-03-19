import AppKit
import Foundation
import UserNotifications

@MainActor
class DownloadManager: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    @Published var pendingURL: String = ""
    @Published var currentInfo: VideoInfo?
    @Published var playlistEntries: [PlaylistEntry] = []
    @Published var isPlaylist = false
    @Published var isFetching = false
    @Published var errorMessage: String?

    private let maxConcurrent = 3

    func fetchInfo(url: String, cookieBrowser: String) async {
        isFetching = true
        errorMessage = nil
        currentInfo = nil
        playlistEntries = []
        isPlaylist = false

        do {
            if url.contains("list=") || url.contains("/playlist?") {
                let entries = try await YTDLPService.shared.fetchPlaylist(url: url, cookieBrowser: cookieBrowser)
                if entries.count > 1 {
                    playlistEntries = entries
                    isPlaylist = true
                    isFetching = false
                    return
                }
            }
            let info = try await YTDLPService.shared.fetchInfo(url: url, cookieBrowser: cookieBrowser)
            currentInfo = info
        } catch {
            errorMessage = error.localizedDescription
        }
        isFetching = false
    }

    func startDownload(
        url: String,
        title: String = "",
        thumbnail: String = "",
        format: DownloadFormat,
        quality: VideoQuality,
        cookieBrowser: String,
        downloadDir: String
    ) {
        let job = DownloadJob(url: url, title: title, thumbnail: thumbnail)
        jobs.insert(job, at: 0)

        Task.detached { [weak self] in
            await YTDLPService.shared.startDownload(
                job: job, format: format, quality: quality,
                cookieBrowser: cookieBrowser, downloadDir: downloadDir
            )

            await MainActor.run {
                if job.status == .done {
                    self?.sendNotification(title: job.title.isEmpty ? "Download Complete" : job.title)
                    let filesize: Int64
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: job.filename),
                       let size = attrs[.size] as? Int64 {
                        filesize = size
                    } else {
                        filesize = 0
                    }
                    HistoryStore.shared.add(
                        url: job.url, title: job.title.isEmpty ? (job.filename as NSString).lastPathComponent : job.title,
                        filename: job.filename, format: format.rawValue,
                        duration: 0, filesize: filesize, thumbnail: job.thumbnail
                    )
                }
            }
        }
    }

    func startPlaylistDownload(
        entries: [PlaylistEntry],
        format: DownloadFormat,
        quality: VideoQuality,
        cookieBrowser: String,
        downloadDir: String
    ) {
        let selected = entries.filter { $0.selected }
        for (index, entry) in selected.enumerated() {
            let url = entry.url.hasPrefix("http") ? entry.url : "https://www.youtube.com/watch?v=\(entry.url)"
            // Stagger starts to respect maxConcurrent
            let delay = max(0, index - maxConcurrent + 1)
            Task {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(Double(delay) * 2))
                }
                // Wait for a slot
                while activeCount >= maxConcurrent {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                startDownload(
                    url: url, title: entry.title,
                    format: format, quality: quality,
                    cookieBrowser: cookieBrowser, downloadDir: downloadDir
                )
            }
        }
    }

    func cancelJob(_ job: DownloadJob) {
        if let process = job.process, process.isRunning {
            process.interrupt()  // SIGINT -- yt-dlp handles gracefully and cleans up children
        }
        job.status = .cancelled
        job.error = "Cancelled"
    }

    func revealInFinder(_ job: DownloadJob) {
        guard !job.filename.isEmpty else { return }
        let url = URL(fileURLWithPath: job.filename)
        if FileManager.default.fileExists(atPath: job.filename) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openDownloadFolder(path: String) {
        let dir = path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Grabby")
            : URL(fileURLWithPath: path)
        NSWorkspace.shared.open(dir)
    }

    func reset() {
        currentInfo = nil
        playlistEntries = []
        isPlaylist = false
        errorMessage = nil
        pendingURL = ""
    }

    private func sendNotification(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Grabby"
        content.body = "Downloaded: \(title)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    var activeCount: Int {
        jobs.filter { $0.status == .downloading || $0.status == .queued }.count
    }
}
