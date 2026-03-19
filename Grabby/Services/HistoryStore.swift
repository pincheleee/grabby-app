import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published var items: [HistoryItem] = []

    private var db: OpaquePointer?
    nonisolated let dbPath: String

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grabby")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        dbPath = appSupport.appendingPathComponent("history.db").path
        openDB()
        createTable()
        load()
    }

    private func openDB() {
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            print("Failed to open database")
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_busy_timeout(db, 10000)
    }

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT,
                title TEXT,
                filename TEXT,
                format TEXT,
                duration INTEGER DEFAULT 0,
                filesize INTEGER DEFAULT 0,
                downloaded_at TEXT,
                thumbnail TEXT
            )
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func safeText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    func load() {
        items = []
        let sql = "SELECT id, url, title, filename, format, duration, filesize, downloaded_at, thumbnail FROM history ORDER BY id DESC LIMIT 50"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let dateFormatter = ISO8601DateFormatter()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let url = safeText(stmt, 1)
            let title = safeText(stmt, 2)
            let filename = safeText(stmt, 3)
            let format = safeText(stmt, 4)
            let duration = Int(sqlite3_column_int(stmt, 5))
            let filesize = sqlite3_column_int64(stmt, 6)
            let dateStr = safeText(stmt, 7)
            let thumbnail = safeText(stmt, 8)

            let date = dateFormatter.date(from: dateStr) ?? Date()

            items.append(HistoryItem(
                id: id, url: url, title: title, filename: filename,
                format: format, duration: duration, filesize: filesize,
                downloadedAt: date, thumbnail: thumbnail
            ))
        }
    }

    nonisolated func add(url: String, title: String, filename: String, format: String,
                          duration: Int, filesize: Int64, thumbnail: String) {
        let dbPath = self.dbPath
        DispatchQueue.global().async {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            sqlite3_busy_timeout(db, 10000)
            let sql = "INSERT INTO history (url, title, filename, format, duration, filesize, downloaded_at, thumbnail) VALUES (?,?,?,?,?,?,?,?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let dateStr = ISO8601DateFormatter().string(from: Date())
            sqlite3_bind_text(stmt, 1, (url as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (format as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(duration))
            sqlite3_bind_int64(stmt, 6, filesize)
            sqlite3_bind_text(stmt, 7, (dateStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, (thumbnail as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)

            DispatchQueue.main.async {
                HistoryStore.shared.load()
            }
        }
    }

    func clearAll() {
        sqlite3_exec(db, "DELETE FROM history", nil, nil, nil)
        items = []
    }

    deinit {
        sqlite3_close(db)
    }
}
