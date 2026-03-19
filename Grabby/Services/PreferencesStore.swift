import Foundation
import SwiftUI

@MainActor
class PreferencesStore: ObservableObject {
    @Published var format: DownloadFormat = .mp4
    @Published var quality: VideoQuality = .best
    @Published var audioFormat: DownloadFormat = .mp3
    @Published var cookieBrowser: String = ""
    @Published var downloadDir: String = ""
    @Published var theme: String = "dark"

    private let prefsURL: URL

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabby")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        prefsURL = appSupport.appendingPathComponent("prefs.json")

        // Default download dir
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Grabby").path
        downloadDir = defaultDir
        try? FileManager.default.createDirectory(atPath: defaultDir, withIntermediateDirectories: true)

        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: prefsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let f = json["format"] as? String, let fmt = DownloadFormat(rawValue: f) { format = fmt }
        if let q = json["quality"] as? String, let qual = VideoQuality(rawValue: q) { quality = qual }
        if let af = json["audio_format"] as? String, let afmt = DownloadFormat(rawValue: af) { audioFormat = afmt }
        if let cb = json["cookie_browser"] as? String { cookieBrowser = cb }
        if let dd = json["download_dir"] as? String, !dd.isEmpty { downloadDir = dd }
        if let t = json["theme"] as? String { theme = t }
    }

    func save() {
        let json: [String: Any] = [
            "format": format.rawValue,
            "quality": quality.rawValue,
            "audio_format": audioFormat.rawValue,
            "cookie_browser": cookieBrowser,
            "download_dir": downloadDir,
            "theme": theme,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: prefsURL)
        }
    }

    var effectiveFormat: DownloadFormat { format }
    var effectiveQuality: VideoQuality { quality }
}
