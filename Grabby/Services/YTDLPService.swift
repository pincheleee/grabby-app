import Foundation

enum BinarySource: String, Equatable {
    case managed
    case bundled
    case homebrew
    case missing

    var label: String {
        switch self {
        case .managed: return "Managed"
        case .bundled: return "Bundled"
        case .homebrew: return "Homebrew"
        case .missing: return "Missing"
        }
    }
}

struct BinaryStatus: Equatable {
    let name: String
    let path: String
    let source: BinarySource

    var isAvailable: Bool {
        source != .missing && !path.isEmpty
    }

    var pathLabel: String {
        isAvailable ? path : "Missing"
    }
}

struct DependencyStatus: Equatable {
    let ytdlp: BinaryStatus
    let ffmpeg: BinaryStatus
}

struct ParsedYTDLPLine: Equatable {
    var progress: Double?
    var speed: String?
    var eta: String?
    var destination: String?
    var size: String?
    var finalPath: String?

    var isEmpty: Bool {
        progress == nil &&
        speed == nil &&
        eta == nil &&
        destination == nil &&
        size == nil &&
        finalPath == nil
    }
}

actor YTDLPService {
    static let shared = YTDLPService()

    // Static regex for progress parsing (compiled once, reused across downloads)
    private static let finalPathPrefix = "__GRABBY_FINAL_PATH__:"
    private static let progressRegex = try! NSRegularExpression(pattern: #"(\d+\.?\d*)%"#)
    private static let speedRegex = try! NSRegularExpression(pattern: #"(\d+\.?\d*\s*[KMG]iB/s)"#)
    private static let etaRegex = try! NSRegularExpression(pattern: #"ETA\s+(\S+)"#)
    private static let destRegex = try! NSRegularExpression(pattern: #"Destination:\s+(.+)$"#, options: .anchorsMatchLines)
    private static let sizeRegex = try! NSRegularExpression(pattern: #"of\s+~?\s*(\d+\.?\d*\s*[KMG]iB)"#)

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

    nonisolated static func buildInfoArgs(url: String, cookieBrowser: String) -> [String] {
        var args = ["--dump-json", "--no-download"]
        if !cookieBrowser.isEmpty {
            args += ["--cookies-from-browser", cookieBrowser]
        }
        args += ["--", url]
        return args
    }

    nonisolated static func buildPlaylistArgs(url: String, cookieBrowser: String) -> [String] {
        var args = ["--flat-playlist", "--dump-json", "--no-download"]
        if !cookieBrowser.isEmpty {
            args += ["--cookies-from-browser", cookieBrowser]
        }
        args += ["--", url]
        return args
    }

    nonisolated static func buildDownloadArgs(
        url: String,
        format: DownloadFormat,
        quality: VideoQuality,
        cookieBrowser: String,
        downloadDir: String,
        ffmpegDir: String
    ) -> [String] {
        var args = [
            "--newline", "--progress",
            "--restrict-filenames",
            "--paths", downloadDir,
            "--print", "after_move:\(finalPathPrefix)%(filepath)s",
            "-o", "%(title)s.%(ext)s",
        ]

        if !ffmpegDir.isEmpty {
            args += ["--ffmpeg-location", ffmpegDir]
        }

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

        args += ["--", url]
        return args
    }

    nonisolated static func parseOutputLine(_ rawLine: String) -> ParsedYTDLPLine? {
        let s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let finalPath = parseFinalPath(s) {
            return ParsedYTDLPLine(finalPath: finalPath)
        }

        let range = NSRange(s.startIndex..., in: s)
        var parsed = ParsedYTDLPLine()

        if let m = progressRegex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s),
           let val = Double(s[r]) {
            parsed.progress = val
        }
        if let m = speedRegex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s) {
            parsed.speed = String(s[r])
        }
        if let m = etaRegex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s) {
            parsed.eta = String(s[r])
        }
        if let m = destRegex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s) {
            parsed.destination = String(s[r]).trimmingCharacters(in: .whitespaces)
        }
        if let m = sizeRegex.firstMatch(in: s, range: range),
           let r = Range(m.range(at: 1), in: s) {
            parsed.size = String(s[r])
        }

        return parsed.isEmpty ? nil : parsed
    }

    nonisolated static func managedToolsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabby/bin", isDirectory: true)
    }

    nonisolated static func managedYTDLPPath() -> String {
        managedToolsDir().appendingPathComponent("yt-dlp").path
    }

    nonisolated static func bundledBinaryPath(named name: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: nil),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    nonisolated static func homebrewBinaryPath(named name: String) -> String? {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    nonisolated static func resolveBinary(name: String, candidates: [(BinarySource, String?)]) -> BinaryStatus {
        for (source, path) in candidates {
            if let path, FileManager.default.isExecutableFile(atPath: path) {
                return BinaryStatus(name: name, path: path, source: source)
            }
        }
        return BinaryStatus(name: name, path: "", source: .missing)
    }

    nonisolated static func resolveYTDLP() -> BinaryStatus {
        resolveBinary(name: "yt-dlp", candidates: [
            (.managed, managedYTDLPPath()),
            (.bundled, bundledBinaryPath(named: "yt-dlp")),
            (.homebrew, homebrewBinaryPath(named: "yt-dlp")),
        ])
    }

    nonisolated static func resolveFFmpeg() -> BinaryStatus {
        resolveBinary(name: "ffmpeg", candidates: [
            (.bundled, bundledBinaryPath(named: "ffmpeg")),
            (.homebrew, homebrewBinaryPath(named: "ffmpeg")),
        ])
    }

    private func ytdlpPath() -> String {
        Self.resolveYTDLP().path
    }

    private func ffmpegDir() -> String {
        let ffmpeg = Self.resolveFFmpeg()
        guard ffmpeg.isAvailable else { return "" }
        return (ffmpeg.path as NSString).deletingLastPathComponent
    }

    private func enhancedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [ffmpegDir(), "/opt/homebrew/bin", "/usr/local/bin"].filter { !$0.isEmpty }
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
        let status = dependencyStatus()
        return (status.ytdlp.isAvailable, status.ffmpeg.isAvailable)
    }

    func dependencyStatus() -> DependencyStatus {
        DependencyStatus(
            ytdlp: Self.resolveYTDLP(),
            ffmpeg: Self.resolveFFmpeg()
        )
    }

    private func validateURL(_ url: String) throws {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw GrabbyError.ytdlp("Only http/https URLs are supported.")
        }
    }

    nonisolated static func parseFinalPath(_ line: String) -> String? {
        guard line.hasPrefix(finalPathPrefix) else { return nil }
        let path = String(line.dropFirst(finalPathPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func fetchInfo(url: String, cookieBrowser: String) async throws -> VideoInfo {
        try validateURL(url)
        let (stdout, stderr, code) = try await run(
            args: Self.buildInfoArgs(url: url, cookieBrowser: cookieBrowser),
            timeout: 60
        )
        guard code == 0 else {
            throw GrabbyError.ytdlp(Self.parseErrorText(stderr))
        }
        guard let data = stdout.data(using: .utf8) else {
            throw GrabbyError.ytdlp("Failed to parse video info")
        }
        return try JSONDecoder().decode(VideoInfo.self, from: data)
    }

    func fetchPlaylist(url: String, cookieBrowser: String) async throws -> [PlaylistEntry] {
        try validateURL(url)
        let (stdout, stderr, code) = try await run(
            args: Self.buildPlaylistArgs(url: url, cookieBrowser: cookieBrowser),
            timeout: 120
        )
        guard code == 0 else {
            throw GrabbyError.ytdlp(Self.parseErrorText(stderr))
        }
        let maxEntries = 500
        var entries: [PlaylistEntry] = []
        for (i, line) in stdout.split(separator: "\n").enumerated() {
            guard !line.isEmpty else { continue }
            guard entries.count < maxEntries else { break }
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

        let execPath = ytdlpPath()
        let env = enhancedEnv()
        let args = Self.buildDownloadArgs(
            url: job.url,
            format: format,
            quality: quality,
            cookieBrowser: cookieBrowser,
            downloadDir: dir,
            ffmpegDir: ffmpegDir()
        )

        guard !execPath.isEmpty else {
            await MainActor.run {
                job.status = .error
                job.error = "yt-dlp is missing. Rebuild Grabby or install yt-dlp first."
            }
            return
        }

        // Create process on MainActor before dispatching to background (avoids race on job.process)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.qualityOfService = .userInitiated

        await MainActor.run {
            job.process = process
            job.status = .downloading
        }

        // Run blocking I/O off the cooperative thread pool
        let capturedDir = dir
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {

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
                var lastLines: [String] = []  // Only keep last 50 lines for error parsing
                var resolvedFinalPath = ""
                var lineBuffer = ""

                func processLine(_ rawLine: String) {
                    let s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !s.isEmpty else { return }

                    lastLines.append(s)
                    if lastLines.count > 50 { lastLines = Array(lastLines.suffix(50)) }

                    guard let parsed = Self.parseOutputLine(s) else { return }

                    if let finalPath = parsed.finalPath {
                        resolvedFinalPath = finalPath
                        DispatchQueue.main.async { job.filename = finalPath }
                        return
                    }

                    if let progress = parsed.progress {
                        DispatchQueue.main.async { job.progress = progress }
                    }
                    if let speed = parsed.speed {
                        DispatchQueue.main.async { job.speed = speed }
                    }
                    if let eta = parsed.eta {
                        DispatchQueue.main.async { job.eta = eta }
                    }
                    if let destination = parsed.destination {
                        DispatchQueue.main.async { job.filename = destination }
                    }
                    if let size = parsed.size {
                        DispatchQueue.main.async { job.filesizeStr = size }
                    }
                }

                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    guard let text = String(data: data, encoding: .utf8) else { continue }

                    lineBuffer += text

                    while let newlineRange = lineBuffer.range(of: "\n") {
                        let line = String(lineBuffer[..<newlineRange.lowerBound])
                        lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)
                        processLine(line)
                    }
                }

                if !lineBuffer.isEmpty {
                    processLine(lineBuffer)
                }

                handle.closeFile()  // Explicitly close read-side fd
                process.waitUntilExit()
                let exitCode = process.terminationStatus

                DispatchQueue.main.async {
                    if exitCode == 0 {
                        job.status = .done
                        job.progress = 100
                        if !resolvedFinalPath.isEmpty {
                            job.filename = resolvedFinalPath
                        } else if job.filename.isEmpty || !FileManager.default.fileExists(atPath: job.filename) {
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
                        job.error = YTDLPService.parseErrorText(lastLines.joined(separator: "\n"))
                    }
                    job.process = nil  // Release Process + pipe references
                }

                continuation.resume()
            }
        }
    }

    func updateYTDLP() async -> String {
        let current = Self.resolveYTDLP()
        guard current.isAvailable else {
            return "yt-dlp is missing. Rebuild Grabby or install yt-dlp first."
        }

        if current.source == .homebrew {
            return "Grabby is using Homebrew yt-dlp. Update it with Homebrew instead of modifying it from inside the app."
        }

        let execPath: String
        let installedManagedCopy: Bool

        do {
            if current.source == .managed {
                execPath = current.path
                installedManagedCopy = false
            } else {
                execPath = try installManagedYTDLPIfNeeded()
                installedManagedCopy = true
            }

            let (stdout, stderr, code) = try await run(execPath: execPath, args: ["-U"], timeout: 60)
            let output = stdout + stderr
            if output.lowercased().contains("is up to date") {
                return installedManagedCopy
                    ? "Managed yt-dlp installed and is already up to date."
                    : "Managed yt-dlp is already up to date."
            } else if code == 0 {
                return installedManagedCopy
                    ? "Managed yt-dlp installed and updated successfully."
                    : "Managed yt-dlp updated successfully."
            } else {
                return "Update failed: \(output.prefix(200))"
            }
        } catch {
            return "Update failed: \(error.localizedDescription)"
        }
    }

    // Run yt-dlp and capture all output -- runs blocking I/O off cooperative pool
    private func run(execPath explicitExecPath: String? = nil, args: [String], timeout: TimeInterval) async throws -> (String, String, Int32) {
        let execPath = explicitExecPath ?? ytdlpPath()
        let env = enhancedEnv()

        guard !execPath.isEmpty else {
            throw GrabbyError.general("yt-dlp is missing. Rebuild Grabby or install yt-dlp first.")
        }

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

                // Timeout
                let timer = DispatchWorkItem { process.terminate() }

                do {
                    try process.run()
                } catch {
                    timer.cancel()
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                stdoutPipe.fileHandleForReading.closeFile()
                stderrPipe.fileHandleForReading.closeFile()
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

    private func installManagedYTDLPIfNeeded() throws -> String {
        let managedPath = Self.managedYTDLPPath()
        if FileManager.default.isExecutableFile(atPath: managedPath) {
            return managedPath
        }

        guard let bundledPath = Self.bundledBinaryPath(named: "yt-dlp") else {
            throw GrabbyError.general("Managed updates require the bundled yt-dlp binary. Rebuild Grabby if it is missing.")
        }

        let managedDir = Self.managedToolsDir()
        try FileManager.default.createDirectory(at: managedDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: managedPath) {
            try FileManager.default.removeItem(atPath: managedPath)
        }

        try FileManager.default.copyItem(atPath: bundledPath, toPath: managedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedPath)
        return managedPath
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
