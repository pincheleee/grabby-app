import Foundation

enum DownloadStatus: String {
    case queued, downloading, done, error, cancelled
}

enum DownloadFormat: String, CaseIterable, Identifiable {
    // Video
    case mp4, mkv, webm
    // Audio
    case mp3, flac, m4a, wav, opus

    var id: String { rawValue }

    var label: String {
        rawValue.uppercased()
    }

    var isAudio: Bool {
        switch self {
        case .mp3, .flac, .m4a, .wav, .opus: return true
        default: return false
        }
    }

    static var videoFormats: [DownloadFormat] { [.mp4, .mkv, .webm] }
    static var audioFormats: [DownloadFormat] { [.mp3, .flac, .m4a, .wav, .opus] }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best, q1080 = "1080", q720 = "720", q480 = "480", q360 = "360"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best Available"
        case .q1080: return "1080p"
        case .q720: return "720p"
        case .q480: return "480p"
        case .q360: return "360p"
        }
    }
}

@MainActor
class DownloadJob: ObservableObject, Identifiable {
    let id: String
    let url: String
    let title: String
    let thumbnail: String

    @Published var status: DownloadStatus = .queued
    @Published var progress: Double = 0
    @Published var speed: String = ""
    @Published var eta: String = ""
    @Published var filename: String = ""
    @Published var error: String = ""
    @Published var filesizeStr: String = ""

    var process: Process?
    let createdAt: Date

    init(url: String, title: String = "", thumbnail: String = "") {
        self.id = UUID().uuidString.prefix(12).lowercased()
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.createdAt = Date()
    }
}
