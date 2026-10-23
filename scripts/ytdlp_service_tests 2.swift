import Foundation

struct TestFailure: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@main
struct YTDLPServiceTests {
    static func main() {
        do {
            try testInfoArgs()
            try testPlaylistArgs()
            try testVideoDownloadArgs()
            try testAudioDownloadArgs()
            try testFinalPathParsing()
            try testProgressParsing()
            try testDestinationParsing()
            try testErrorParsing()
            print("All YTDLPService tests passed.")
        } catch {
            fputs("YTDLPService tests failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testInfoArgs() throws {
        let url = "https://www.youtube.com/watch?v=abc123"
        let args = YTDLPService.buildInfoArgs(url: url, cookieBrowser: "chrome")
        try expectEqual(
            args,
            ["--dump-json", "--no-download", "--cookies-from-browser", "chrome", "--", url],
            "Info args should keep cookie flags before the URL sentinel."
        )
    }

    private static func testPlaylistArgs() throws {
        let url = "https://www.youtube.com/playlist?list=abc123"
        let args = YTDLPService.buildPlaylistArgs(url: url, cookieBrowser: "firefox")
        try expectEqual(
            args,
            ["--flat-playlist", "--dump-json", "--no-download", "--cookies-from-browser", "firefox", "--", url],
            "Playlist args should keep cookie flags before the URL sentinel."
        )
    }

    private static func testVideoDownloadArgs() throws {
        let url = "https://www.youtube.com/watch?v=abc123"
        let args = YTDLPService.buildDownloadArgs(
            url: url,
            format: .mp4,
            quality: .q720,
            cookieBrowser: "chrome",
            downloadDir: "/tmp/grabby",
            ffmpegDir: "/opt/homebrew/bin"
        )

        try expectEqual(
            args,
            [
                "--newline", "--progress",
                "--restrict-filenames",
                "--paths", "/tmp/grabby",
                "--print", "after_move:__GRABBY_FINAL_PATH__:%(filepath)s",
                "-o", "%(title)s.%(ext)s",
                "--ffmpeg-location", "/opt/homebrew/bin",
                "--cookies-from-browser", "chrome",
                "-f", "bestvideo[height<=720]+bestaudio/best[height<=720]",
                "--merge-output-format", "mp4",
                "--", url,
            ],
            "Video download args should be deterministic and cookie-safe."
        )
    }

    private static func testAudioDownloadArgs() throws {
        let url = "https://www.youtube.com/watch?v=abc123"
        let args = YTDLPService.buildDownloadArgs(
            url: url,
            format: .mp3,
            quality: .best,
            cookieBrowser: "",
            downloadDir: "/tmp/grabby",
            ffmpegDir: ""
        )

        try expectEqual(
            args,
            [
                "--newline", "--progress",
                "--restrict-filenames",
                "--paths", "/tmp/grabby",
                "--print", "after_move:__GRABBY_FINAL_PATH__:%(filepath)s",
                "-o", "%(title)s.%(ext)s",
                "-x", "--audio-format", "mp3", "--audio-quality", "0",
                "--", url,
            ],
            "Audio download args should omit merge flags and still terminate options before the URL."
        )
    }

    private static func testFinalPathParsing() throws {
        let parsed = YTDLPService.parseOutputLine("__GRABBY_FINAL_PATH__:/tmp/final.mp4")
        try expectEqual(parsed?.finalPath, "/tmp/final.mp4", "Final path lines should be parsed exactly.")
    }

    private static func testProgressParsing() throws {
        let parsed = YTDLPService.parseOutputLine("[download]  12.3% of ~4.56MiB at 1.23MiB/s ETA 00:11")
        try expectEqual(parsed?.progress, 12.3, "Progress percentage should parse from yt-dlp output.")
        try expectEqual(parsed?.speed, "1.23MiB/s", "Transfer speed should parse from yt-dlp output.")
        try expectEqual(parsed?.eta, "00:11", "ETA should parse from yt-dlp output.")
        try expectEqual(parsed?.size, "4.56MiB", "Approximate size should parse from yt-dlp output.")
    }

    private static func testDestinationParsing() throws {
        let parsed = YTDLPService.parseOutputLine("[download] Destination: /tmp/intermediate.mp4")
        try expectEqual(parsed?.destination, "/tmp/intermediate.mp4", "Destination lines should parse their output path.")
    }

    private static func testErrorParsing() throws {
        let parsed = YTDLPService.parseErrorText("ERROR: Private video")
        try expectEqual(parsed, "This video is private or unavailable.", "Friendly error parsing should preserve mapped messages.")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message: message)
        }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        try expect(actual == expected, "\(message)\nExpected: \(expected)\nActual: \(actual)")
    }
}
