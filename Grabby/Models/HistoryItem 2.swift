import Foundation

struct HistoryItem: Identifiable {
    let id: Int64
    let url: String
    let title: String
    let filename: String
    let format: String
    let duration: Int
    let filesize: Int64
    let downloadedAt: Date
    let thumbnail: String

    var filesizeString: String {
        guard filesize > 0 else { return "" }
        if filesize >= 1_000_000_000 { return String(format: "%.1f GB", Double(filesize) / 1_000_000_000) }
        if filesize >= 1_000_000 { return String(format: "%.1f MB", Double(filesize) / 1_000_000) }
        if filesize >= 1_000 { return String(format: "%.0f KB", Double(filesize) / 1_000) }
        return "\(filesize) B"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var dateString: String {
        Self.dateFormatter.string(from: downloadedAt)
    }
}
