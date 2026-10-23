import Foundation

@main
struct GrabbyRuntimeSmoke {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let url = args.first ?? "https://www.youtube.com/watch?v=BaW_jenozKc"
        let cookieBrowserArg = args.count > 1 ? args[1] : ""
        let cookieBrowser = cookieBrowserArg == "none" ? "" : cookieBrowserArg
        let action = args.count > 2 ? args[2] : "download"
        let qualityArg = args.count > 3 ? args[3] : "360"
        let quality: VideoQuality = switch qualityArg {
        case "1080": .q1080
        case "720": .q720
        case "480": .q480
        case "best": .best
        default: .q360
        }
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grabby-runtime-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let info = try await YTDLPService.shared.fetchInfo(url: url, cookieBrowser: cookieBrowser)
            print("FETCH_OK title=\(info.title)")

            guard action != "fetch" else { return }

            let job = await MainActor.run {
                DownloadJob(url: url, title: info.title, thumbnail: info.thumbnail)
            }

            await YTDLPService.shared.startDownload(
                job: job,
                format: .mp4,
                quality: quality,
                cookieBrowser: cookieBrowser,
                downloadDir: outputDir.path
            )

            let result = await MainActor.run {
                (
                    status: job.status.rawValue,
                    filename: job.filename,
                    error: job.error,
                    progress: job.progress,
                    exists: FileManager.default.fileExists(atPath: job.filename)
                )
            }

            print("DOWNLOAD_STATUS \(result.status)")
            print("DOWNLOAD_PROGRESS \(result.progress)")
            print("DOWNLOAD_FILE \(result.filename)")
            if !result.error.isEmpty {
                print("DOWNLOAD_ERROR \(result.error)")
            }

            guard result.status == DownloadStatus.done.rawValue else {
                fputs("Runtime smoke failed: download did not complete\n", stderr)
                exit(1)
            }

            guard !result.filename.isEmpty, result.exists else {
                fputs("Runtime smoke failed: final file path was not resolved to an existing file\n", stderr)
                exit(1)
            }
        } catch {
            fputs("Runtime smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
