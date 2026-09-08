import Foundation
import CryptoKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ItemKind: Int {
    case text = 0
    case image = 1
}

struct ClipItem {
    let id: Int64
    let kind: ItemKind
    let preview: String
    let createdAt: Date
    let charCount: Int
    let width: Int
    let height: Int
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
}

/// SQLite 持久化。内存中只保留当前列表需要的少量字段，正文、缩略图、原图都按需读取。
final class Store {
    private var db: OpaquePointer?
    let maxItems: Int
    let baseDir: URL
    let imagesDir: URL

    init(maxItems: Int) throws {
        self.maxItems = maxItems
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = support.appendingPathComponent("Paste", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let path = baseDir.appendingPathComponent("paste.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError(description: "无法打开数据库: \(path)")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA cache_size=-256")      // 页缓存上限 256KB，控制内存
        try exec("PRAGMA temp_store=MEMORY")
        try exec("""
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                preview TEXT NOT NULL,
                content TEXT NOT NULL,
                char_count INTEGER NOT NULL DEFAULT 0,
                image_path TEXT,
                thumb BLOB,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC)")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - 写入

    /// 返回记录 id。已存在相同内容时只刷新时间并置顶。
    @discardableResult
    func saveText(_ text: String) -> Int64? {
        let hash = Store.sha256(Data(text.utf8))
        if let id = existingId(hash: hash) {
            touch(id: id)
            return id
        }
        let preview = Store.makePreview(text)
        let sql = "INSERT INTO items(kind, hash, preview, content, char_count, created_at) VALUES(?,?,?,?,?,?)"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(ItemKind.text.rawValue))
        sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, preview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(text.count))
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        let id = sqlite3_last_insert_rowid(db)
        prune()
        return id
    }

    @discardableResult
    func saveImage(png: Data, thumb: Data?, width: Int, height: Int) -> Int64? {
        let hash = Store.sha256(png)
        if let id = existingId(hash: hash) {
            touch(id: id)
            return id
        }
        let fileName = "\(hash).png"
        let fileURL = imagesDir.appendingPathComponent(fileName)
        do {
            try png.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        let preview = "图片 \(width)×\(height)"
        let sql = "INSERT INTO items(kind, hash, preview, content, char_count, image_path, thumb, width, height, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(ItemKind.image.rawValue))
        sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, preview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, preview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, 0)
        sqlite3_bind_text(stmt, 6, fileName, -1, SQLITE_TRANSIENT)
        if let thumb = thumb {
            thumb.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(stmt, 7, buf.baseAddress, Int32(thumb.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int64(stmt, 8, Int64(width))
        sqlite3_bind_int64(stmt, 9, Int64(height))
        sqlite3_bind_double(stmt, 10, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let id = sqlite3_last_insert_rowid(db)
        prune()
        return id
    }

    func touch(id: Int64) {
        guard let stmt = prepare("UPDATE items SET created_at=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func delete(id: Int64) {
        if let path = imagePath(id: id) {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(path))
        }
        guard let stmt = prepare("DELETE FROM items WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func clearAll() {
        try? exec("DELETE FROM items")
        try? exec("VACUUM")
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - 读取

    func count() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM items") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func fetch(query: String?, limit: Int) -> [ClipItem] {
        var sql = "SELECT id, kind, preview, created_at, char_count, width, height FROM items"
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !q.isEmpty {
            sql += " WHERE content LIKE ? ESCAPE '\\'"
        }
        sql += " ORDER BY created_at DESC LIMIT ?"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if !q.isEmpty {
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sqlite3_bind_text(stmt, idx, "%\(escaped)%", -1, SQLITE_TRANSIENT)
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var result: [ClipItem] = []
        result.reserveCapacity(min(limit, 64))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = ItemKind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text
            let preview = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: kind,
                preview: preview,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                charCount: Int(sqlite3_column_int64(stmt, 4)),
                width: Int(sqlite3_column_int64(stmt, 5)),
                height: Int(sqlite3_column_int64(stmt, 6))
            ))
        }
        return result
    }

    func fullText(id: Int64) -> String? {
        guard let stmt = prepare("SELECT content FROM items WHERE id=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func thumb(id: Int64) -> Data? {
        guard let stmt = prepare("SELECT thumb FROM items WHERE id=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    func imageData(id: Int64) -> Data? {
        guard let path = imagePath(id: id) else { return nil }
        return try? Data(contentsOf: imagesDir.appendingPathComponent(path))
    }

    // MARK: - 内部

    private func imagePath(id: Int64) -> String? {
        guard let stmt = prepare("SELECT image_path FROM items WHERE id=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func existingId(hash: String) -> Int64? {
        guard let stmt = prepare("SELECT id FROM items WHERE hash=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    /// 超过上限时删除最旧的记录及其图片文件。
    private func prune() {
        guard let stmt = prepare("SELECT id, image_path FROM items ORDER BY created_at DESC LIMIT -1 OFFSET ?") else { return }
        sqlite3_bind_int(stmt, 1, Int32(maxItems))
        var victims: [(Int64, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            victims.append((sqlite3_column_int64(stmt, 0), path))
        }
        sqlite3_finalize(stmt)
        guard !victims.isEmpty, let del = prepare("DELETE FROM items WHERE id=?") else { return }
        defer { sqlite3_finalize(del) }
        for (id, path) in victims {
            if let path = path {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(path))
            }
            sqlite3_reset(del)
            sqlite3_bind_int64(del, 1, id)
            sqlite3_step(del)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("SQLite prepare 失败: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError(description: "SQLite 执行失败: \(msg)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 把多行文本压成一行、去掉多余空白，只保留前 200 个字符用于列表展示。
    static func makePreview(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(200)
        var lastWasSpace = true
        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
            if out.count >= 200 { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
