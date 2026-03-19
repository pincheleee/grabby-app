import Foundation

actor YTDLPService {
    static let shared = YTDLPService()

    // Static so nonisolated functions can access without data race
    private static let errorPatterns: [(String, String)] = [
        ("Sign in to confirm your age|age-restricted",
         "This video is age-restricted. Sign into YouTube in your browser and select that browser for cookies."),
        ("Private video|Video unavailable",
         "This video is private or unavailable."),
        ("geo.?restricted|not available in your country",
         "This video is geo-restricted and not available in your region."),
        ("copyright",
         "This video was removed due to a copyright claim."),
        ("Sign in|login required|cookies",
         "YouTube requires login. Select your browser in Settings and make sure you're signed into YouTube."),
        ("HTTP Error 429|Too Many Requests",
         "Rate limited by YouTube. Wait a few minutes and try again."),
        ("HTTP Error 403|Forbidden",
         "Access forbidden. Try selecting a different browser for cookies."),
        ("is not a valid URL|Unsupported URL",
         "This doesn't look like a valid YouTube URL."),
        ("No video formats found",
         "No downloadable formats found for this video."),
    ]

    private func ytdlpPath() -> String {
        if let bundled = Bundle.main.path(forResource: "yt-dlp", ofType: nil) {
            return bundled
        }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "yt-dlp"  // Let Process fail with a clear error
    }

    private func ffmpegDir() -> String {
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return (bundled as NSString).deletingLastPathComponent
        }
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: p) {
                return (p as NSString).deletingLastPathComponent
            }
        }
        return "/usr/bin"
    }

    private func enhancedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [ffmpegDir(), "/opt/homebrew/bin", "/usr/local/bin"]
        let current = env["PATH"] ?? ""
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    nonisolated static func parseErrorText(_ text: String) -> String {
        for (pattern, message) in errorPatterns {
            if let _ = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return message
            }
        }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("WARNING") }
        if let last = lines.last {
            return last.hasPrefix("ERROR:") ? String(last.dropFirst(6)).trimmingCharacters(in: .whitespaces) : last
        }
        return "Download failed. Check the URL and try again."
    }

    func checkDeps() -> (ytdlp: Bool, ffmpeg: Bool) {
        let ytPath = ytdlpPath()
        let yt = FileManager.default.isExecutableFile(atPath: ytPath)
        let ff = FileManager.default.isExecutableFile(atPath: ffmpegDir() + "/ffmpeg")
        return (yt, ff)
    }

    func fetchInfo(url: String, cookieBrowser: String) async throws -> VideoInfo {
        var args = ["--dump-json", "--no-download", url]
        if !cookieBrowser.isEmpty {
            args += ["--cookies-from-browser", cookieBrowser]
        }
        let (stdout, stderr, code) = try await run(args: args, timeout: 60)
        guard code == 0 else {
            throw GrabbyError.ytdlp(Self.parseErrorText(stderr))
        }
        guard let data = stdout.data(using: .utf8) else {
            throw GrabbyError.ytdlp("Failed to parse video info")
        }
        return try JSONDecoder().decode(VideoInfo.self, from: data)
    }

    func fetchPlaylist(url: String, cookieBrowser: String) async throws -> [PlaylistEntry] {
        var args = ["--flat-playlist", "--dump-json", "--no-download", url]
        if !cookieBrowser.isEmpty {
            args += ["--cookies-from-browser", cookieBrowser]
        }
        let (stdout, stderr, code) = try await run(args: args, timeout: 120)
        guard code == 0 else {
            throw GrabbyError.ytdlp(Self.parseErrorText(stderr))
        }
        var entries: [PlaylistEntry] = []
        for (i, line) in stdout.split(separator: "\n").enumerated() {
            guard !line.isEmpty else { continue }
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let id = json["id"] as? String ?? "\(i)"
                let title = json["title"] as? String ?? "Track \(i + 1)"
                let entryURL = json["url"] as? String ?? json["webpage_url"] as? String ?? id
                let duration = json["duration"] as? Int ?? 0
                entries.append(PlaylistEntry(id: id, title: title, url: entryURL, duration: duration))
            }
        }
        return entries
    }

    func startDownload(
        job: DownloadJob,
        format: DownloadFormat,
        quality: VideoQuality,
        cookieBrowser: String,
        downloadDir: String
    ) async {
        let dir = downloadDir.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Grabby").path
            : downloadDir

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let outputTemplate = "\(dir)/%(title)s.%(ext)s"
        var args = [
            "--newline", "--progress",
            "--ffmpeg-location", ffmpegDir(),
            "-o", outputTemplate,
        ]

        if !cookieBrowser.isEmpty {
            args += ["--cookies-from-browser", cookieBrowser]
        }

        if format.isAudio {
            args += ["-x", "--audio-format", format.rawValue, "--audio-quality", "0"]
        } else {
            let fmtArg: [String]
            switch quality {
            case .best:
                fmtArg = format == .mp4
                    ? ["-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"]
                    : ["-f", "bestvideo+bestaudio/best"]
            case .q1080: fmtArg = ["-f", "bestvideo[height<=1080]+bestaudio/best[height<=1080]"]
            case .q720:  fmtArg = ["-f", "bestvideo[height<=720]+bestaudio/best[height<=720]"]
            case .q480:  fmtArg = ["-f", "bestvideo[height<=480]+bestaudio/best[height<=480]"]
            case .q360:  fmtArg = ["-f", "bestvideo[height<=360]+bestaudio/best[height<=360]"]
            }
            args += fmtArg
            args += ["--merge-output-format", format.rawValue]
        }

        args.append(job.url)

        let execPath = ytdlpPath()
        let env = enhancedEnv()

        await MainActor.run {
            job.status = .downloading
        }

        // Run blocking I/O off the cooperative thread pool
        let capturedDir = dir
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = args
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.qualityOfService = .userInitiated

                DispatchQueue.main.async {
                    job.process = process
                }

                do {
                    try process.run()
                } catch {
                    DispatchQueue.main.async {
                        job.status = .error
                        job.error = error.localizedDescription
                    }
                    continuation.resume()
                    return
                }

                let handle = pipe.fileHandleForReading
                var allOutput = ""
                let progressRegex = try! NSRegularExpression(pattern: #"(\d+\.?\d*)%"#)
                let speedRegex = try! NSRegularExpression(pattern: #"(\d+\.?\d*\s*[KMG]iB/s)"#)
                let etaRegex = try! NSRegularExpression(pattern: #"ETA\s+(\S+)"#)
                let destRegex = try! NSRegularExpression(pattern: #"Destination:\s+(.+)$"#, options: .anchorsMatchLines)
                let sizeRegex = try! NSRegularExpression(pattern: #"of\s+~?\s*(\d+\.?\d*\s*[KMG]iB)"#)

                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    allOutput += text

                    for line in text.split(separator: "\n") {
                        let s = String(line)
                        let range = NSRange(s.startIndex..., in: s)

                        if let m = progressRegex.firstMatch(in: s, range: range),
                           let r = Range(m.range(at: 1), in: s),
                           let val = Double(s[r]) {
                            DispatchQueue.main.async { job.progress = val }
                        }
                        if let m = speedRegex.firstMatch(in: s, range: range),
                           let r = Range(m.range(at: 1), in: s) {
                            DispatchQueue.main.async { job.speed = String(s[r]) }
                        }
                        if let m = etaRegex.firstMatch(in: s, range: range),
                           let r = Range(m.range(at: 1), in: s) {
                            DispatchQueue.main.async { job.eta = String(s[r]) }
                        }
                        if let m = destRegex.firstMatch(in: s, range: range),
                           let r = Range(m.range(at: 1), in: s) {
                            DispatchQueue.main.async { job.filename = String(s[r]).trimmingCharacters(in: .whitespaces) }
                        }
                        if let m = sizeRegex.firstMatch(in: s, range: range),
                           let r = Range(m.range(at: 1), in: s) {
                            DispatchQueue.main.async { job.filesizeStr = String(s[r]) }
                        }
                    }
                }

                process.waitUntilExit()
                let exitCode = process.terminationStatus

                DispatchQueue.main.async {
                    if exitCode == 0 {
                        job.status = .done
                        job.progress = 100
                        if job.filename.isEmpty {
                            if let files = try? FileManager.default.contentsOfDirectory(atPath: capturedDir) {
                                let sorted = files.compactMap { name -> (String, Date)? in
                                    let path = "\(capturedDir)/\(name)"
                                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                                          let date = attrs[.modificationDate] as? Date else { return nil }
                                    return (path, date)
                                }.sorted { $0.1 > $1.1 }
                                job.filename = sorted.first?.0 ?? ""
                            }
                        }
                    } else if job.status != .cancelled {
                        job.status = .error
                        job.error = YTDLPService.parseErrorText(allOutput)
                    }
                }

                continuation.resume()
            }
        }
    }

    func updateYTDLP() async -> String {
        do {
            let (stdout, stderr, code) = try await run(args: ["-U"], timeout: 60)
            let output = stdout + stderr
            if output.lowercased().contains("is up to date") {
                return "yt-dlp is already up to date."
            } else if code == 0 {
                return "yt-dlp updated successfully."
            } else {
                return "Update failed: \(output.prefix(200))"
            }
        } catch {
            return "Update failed: \(error.localizedDescription)"
        }
    }

    // Run yt-dlp and capture all output -- runs blocking I/O off cooperative pool
    private func run(args: [String], timeout: TimeInterval) async throws -> (String, String, Int32) {
        let execPath = ytdlpPath()
        let env = enhancedEnv()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = args
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Timeout
                let timer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                continuation.resume(returning: (
                    String(data: stdoutData, encoding: .utf8) ?? "",
                    String(data: stderrData, encoding: .utf8) ?? "",
                    process.terminationStatus
                ))
            }
        }
    }
}

enum GrabbyError: LocalizedError {
    case ytdlp(String)
    case general(String)

    var errorDescription: String? {
        switch self {
        case .ytdlp(let msg): return msg
        case .general(let msg): return msg
        }
    }
}
