import Foundation

@main
struct GrabbyPlaylistSmoke {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let playlistURL = args.first ?? "https://www.youtube.com/playlist?list=PL-jbbyKiQY-VlYYVIlIcio6tsFYNJ_OU3"
        let cookieBrowserArg = args.count > 1 ? args[1] : ""
        let cookieBrowser = cookieBrowserArg == "none" ? "" : cookieBrowserArg
        let action = args.count > 2 ? args[2] : "download"
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabby-playlist-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let entries = try await YTDLPService.shared.fetchPlaylist(url: playlistURL, cookieBrowser: cookieBrowser)
            print("PLAYLIST_COUNT \(entries.count)")

            guard entries.count > 1 else {
                fputs("Playlist smoke failed: expected multiple entries\n", stderr)
                exit(1)
            }

            guard let first = entries.first else {
                fputs("Playlist smoke failed: no entries returned\n", stderr)
                exit(1)
            }

            print("PLAYLIST_FIRST \(first.title)")

            guard action != "fetch" else { return }

            let videoURL = first.url.hasPrefix("http")
                ? first.url
                : "https://www.youtube.com/watch?v=\(first.url)"

            let job = await MainActor.run {
                DownloadJob(url: videoURL, title: first.title)
            }

            await YTDLPService.shared.startDownload(
                job: job,
                format: .mp4,
                quality: .q360,
                cookieBrowser: cookieBrowser,
                downloadDir: outputDir.path
            )

            let result = await MainActor.run {
                (
                    status: job.status.rawValue,
                    filename: job.filename,
                    error: job.error,
                    exists: FileManager.default.fileExists(atPath: job.filename)
                )
            }

            print("DOWNLOAD_STATUS \(result.status)")
            print("DOWNLOAD_FILE \(result.filename)")
            if !result.error.isEmpty {
                print("DOWNLOAD_ERROR \(result.error)")
            }

            guard result.status == DownloadStatus.done.rawValue else {
                fputs("Playlist smoke failed: entry download did not complete\n", stderr)
                exit(1)
            }

            guard !result.filename.isEmpty, result.exists else {
                fputs("Playlist smoke failed: final file path was not resolved to an existing file\n", stderr)
                exit(1)
            }
        } catch {
            fputs("Playlist smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
