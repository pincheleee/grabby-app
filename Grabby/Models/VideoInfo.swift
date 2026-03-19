import Foundation

struct VideoInfo: Decodable, Identifiable {
    var id: String { url }
    let url: String
    let title: String
    let thumbnail: String
    let duration: Int
    let uploader: String
    let viewCount: Int
    let filesize: Int64

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case thumbnail
        case duration
        case uploader
        case viewCount = "view_count"
        case filesize
        case filesizeApprox = "filesize_approx"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        thumbnail = (try? c.decode(String.self, forKey: .thumbnail)) ?? ""
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        uploader = (try? c.decode(String.self, forKey: .uploader)) ?? ""
        viewCount = (try? c.decode(Int.self, forKey: .viewCount)) ?? 0
        filesize = (try? c.decode(Int64.self, forKey: .filesize)) ??
                   (try? c.decode(Int64.self, forKey: .filesizeApprox)) ?? 0
    }

    init(url: String, title: String, thumbnail: String = "", duration: Int = 0,
         uploader: String = "", viewCount: Int = 0, filesize: Int64 = 0) {
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.duration = duration
        self.uploader = uploader
        self.viewCount = viewCount
        self.filesize = filesize
    }

    var durationString: String {
        guard duration > 0 else { return "" }
        let m = duration / 60
        let s = duration % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    var viewCountString: String {
        if viewCount >= 1_000_000 { return String(format: "%.1fM views", Double(viewCount) / 1_000_000) }
        if viewCount >= 1_000 { return String(format: "%.1fK views", Double(viewCount) / 1_000) }
        if viewCount > 0 { return "\(viewCount) views" }
        return ""
    }

    var filesizeString: String {
        guard filesize > 0 else { return "" }
        if filesize >= 1_000_000_000 { return String(format: "%.1f GB", Double(filesize) / 1_000_000_000) }
        if filesize >= 1_000_000 { return String(format: "%.1f MB", Double(filesize) / 1_000_000) }
        if filesize >= 1_000 { return String(format: "%.0f KB", Double(filesize) / 1_000) }
        return "\(filesize) B"
    }
}

struct PlaylistEntry: Identifiable {
    let id: String
    let title: String
    let url: String
    let duration: Int
    var selected: Bool = true

    var durationString: String {
        guard duration > 0 else { return "" }
        let m = duration / 60
        let s = duration % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
