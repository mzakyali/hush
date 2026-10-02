import AudioCapture
import Foundation
import GRDB
import HushCore

/// One saved dictation (plan T7 `dictations` row).
public struct Dictation: Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var durationSec: Double
    public var appBundleID: String?
    public var appName: String?
    public var rawText: String
    public var cleanedText: String
    public var style: String
    public var cleanupFallback: Bool
    /// Path relative to `AppPaths().audio` (e.g. "<id>.m4a").
    public var audioPath: String?

    public var wordCount: Int {
        cleanedText.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Aggregate stats derived from `stats_daily` (plan T14).
public struct DictationStats: Sendable, Equatable {
    public var totalWords = 0
    public var todayWords = 0
    public var todaySessions = 0
    public var totalSessions = 0
    public var speakingSeconds: Double = 0
    public var typingWPM: Double = 40

    public init(totalWords: Int = 0, todayWords: Int = 0, todaySessions: Int = 0,
                totalSessions: Int = 0, speakingSeconds: Double = 0, typingWPM: Double = 40) {
        self.totalWords = totalWords
        self.todayWords = todayWords
        self.todaySessions = todaySessions
        self.totalSessions = totalSessions
        self.speakingSeconds = speakingSeconds
        self.typingWPM = typingWPM
    }

    /// Spoken words per minute over all speaking time.
    public var spokenWPM: Double {
        speakingSeconds > 0 ? Double(totalWords) / (speakingSeconds / 60) : 0
    }
    /// Speaking time it would have taken to type the same words, minus actual
    /// speaking time (plan T14: words / typingWPM − speakingSeconds).
    public var timeSavedSeconds: Double {
        Double(totalWords) / typingWPM * 60 - speakingSeconds
    }
}

/// One row of `app_styles` — a user override, or (for `dictationApps()`)
/// a bundleID/name pair seen in history with `style` empty.
public struct AppStyleOverride: Sendable, Equatable {
    public var bundleID: String
    public var appName: String?
    public var style: String

    public init(bundleID: String, appName: String? = nil, style: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.style = style
    }
}

/// What the pipeline hands the store after a completed dictation.
public struct DictationInput: Sendable {
    public var rawText: String
    public var cleanedText: String
    public var style: String
    public var cleanupFallback: Bool
    public var durationSec: Double
    public var appBundleID: String?
    public var appName: String?
    public var audio: AudioBuffer16k?

    public init(rawText: String, cleanedText: String, style: String,
                cleanupFallback: Bool, durationSec: Double,
                appBundleID: String? = nil, appName: String? = nil,
                audio: AudioBuffer16k? = nil) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.style = style
        self.cleanupFallback = cleanupFallback
        self.durationSec = durationSec
        self.appBundleID = appBundleID
        self.appName = appName
        self.audio = audio
    }
}

/// GRDB store (plan T7): `dictations` + `stats_daily` + `app_styles` + the
/// tables later milestones need (`dictionary_entries`, `suggestions`).
/// Audio goes to `<audioDir>/<id>.m4a` via `AudioEncoder`.
public actor DictationStore {
    public static let defaultRetentionDays = 30

    private let db: DatabaseQueue
    /// Directory audio files are written to / deleted from.
    public nonisolated let audioDirectory: URL

    public init(paths: AppPaths = AppPaths()) throws {
        try paths.createDirectories()
        self.audioDirectory = paths.audio
        db = try DatabaseQueue(path: paths.database.path)
        try Self.migrate(db)
    }

    /// In-memory / temp-dir store for tests and UI snapshots.
    public init(inMemoryAt directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appending(path: "hush-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.audioDirectory = dir.appending(path: "audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: dir.appending(path: "hush.sqlite").path)
        try Self.migrate(db)
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictations") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .double).notNull()
                t.column("durationSec", .double).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("rawText", .text).notNull()
                t.column("cleanedText", .text).notNull()
                t.column("style", .text).notNull()
                t.column("cleanupFallback", .boolean).notNull()
                t.column("audioPath", .text)
            }
            try db.create(table: "dictionary_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()           // 'term' | 'replacement'
                t.column("fromText", .text)
                t.column("toText", .text).notNull()
                t.column("source", .text).notNull()         // 'manual' | 'learned' | 'history'
                t.column("createdAt", .double).notNull()
                t.column("hitCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "suggestions") { t in
                t.column("id", .text).primaryKey()
                t.column("fromText", .text).notNull()
                t.column("toText", .text).notNull()
                t.column("seenCount", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()         // 'pending' | 'accepted' | 'rejected'
                t.column("lastSeenAt", .double).notNull()
                t.uniqueKey(["fromText", "toText"])
            }
            try db.create(table: "app_styles") { t in
                t.column("bundleID", .text).primaryKey()
                t.column("style", .text).notNull()
            }
            try db.create(table: "stats_daily") { t in
                t.column("day", .text).primaryKey()          // YYYY-MM-DD
                t.column("words", .integer).notNull().defaults(to: 0)
                t.column("sessions", .integer).notNull().defaults(to: 0)
                t.column("speakingSeconds", .double).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE app_styles ADD COLUMN appName TEXT")
            // stats_daily has been bumped inside save() since v1, but a DB
            // that predates per-save aggregation (or one whose stats were
            // cleared) gets its missing days back here. Days already present
            // are authoritative: retention/deletes intentionally keep their
            // aggregates, so recomputing them from surviving rows would
            // silently shrink the user's totals.
            try backfillDailyStats(db)
        }
        try migrator.migrate(db)
    }

    /// Insert `stats_daily` rows for days that have dictations but no
    /// aggregate row (§7/§3.15). Existing rows are left untouched.
    static func backfillDailyStats(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT createdAt, cleanedText, durationSec FROM dictations
            """)
        var perDay: [String: (words: Int, sessions: Int, seconds: Double)] = [:]
        for row in rows {
            let day = dayKey(Date(timeIntervalSince1970: row["createdAt"]))
            let words = (row["cleanedText"] as String)
                .split(whereSeparator: { $0.isWhitespace }).count
            var agg = perDay[day] ?? (0, 0, 0)
            agg.words += words
            agg.sessions += 1
            agg.seconds += row["durationSec"] as Double
            perDay[day] = agg
        }
        for (day, agg) in perDay {
            try db.execute(sql: """
                INSERT INTO stats_daily (day, words, sessions, speakingSeconds)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(day) DO NOTHING
                """, arguments: [day, agg.words, agg.sessions, agg.seconds])
        }
    }

    // MARK: - write

    /// Save a completed dictation: m4a file, `dictations` row, `stats_daily` bump.
    @discardableResult
    public func save(_ input: DictationInput, at now: Date = Date()) throws -> Dictation {
        let id = UUID().uuidString
        var audioPath: String? = nil
        if let audio = input.audio {
            let name = "\(id).m4a"
            try AudioEncoder.writeM4A(audio, to: audioDirectory.appending(path: name))
            audioPath = name
        }
        let row = Dictation(
            id: id, createdAt: now, durationSec: input.durationSec,
            appBundleID: input.appBundleID, appName: input.appName,
            rawText: input.rawText, cleanedText: input.cleanedText,
            style: input.style, cleanupFallback: input.cleanupFallback,
            audioPath: audioPath
        )
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO dictations
                (id, createdAt, durationSec, appBundleID, appName, rawText, cleanedText,
                 style, cleanupFallback, audioPath)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    row.id, row.createdAt.timeIntervalSince1970, row.durationSec,
                    row.appBundleID, row.appName, row.rawText, row.cleanedText,
                    row.style, row.cleanupFallback, row.audioPath,
                ])
            try db.execute(sql: """
                INSERT INTO stats_daily (day, words, sessions, speakingSeconds)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(day) DO UPDATE SET
                    words = words + excluded.words,
                    sessions = sessions + 1,
                    speakingSeconds = speakingSeconds + excluded.speakingSeconds
                """, arguments: [Self.dayKey(now), row.wordCount, row.durationSec])
        }
        return row
    }

    /// Delete one dictation row and its audio file.
    public func delete(id: String) throws {
        guard let row = try db.read({ db in
            try Row.fetchOne(db, sql: "SELECT audioPath FROM dictations WHERE id = ?",
                             arguments: [id])
        }) else { return }
        if let path = row["audioPath"] as String? {
            try? FileManager.default.removeItem(at: audioDirectory.appending(path: path))
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE id = ?", arguments: [id])
        }
    }

    /// Delete every dictation row and its audio file. `stats_daily` aggregates
    /// are untouched (plan T14: aggregates are not touched by retention).
    @discardableResult
    public func deleteAll() throws -> Int {
        let paths = try db.read { db in
            try String.fetchAll(db, sql: "SELECT audioPath FROM dictations WHERE audioPath IS NOT NULL")
        }
        for path in paths {
            try? FileManager.default.removeItem(at: audioDirectory.appending(path: path))
        }
        return try db.write { db in
            try db.execute(sql: "DELETE FROM dictations")
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    /// Retention (plan T7): delete rows + audio files older than `retentionDays`.
    /// Aggregates in `stats_daily` survive.
    @discardableResult
    public func enforceRetention(days: Int = defaultRetentionDays, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let paths = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT audioPath FROM dictations WHERE createdAt < ? AND audioPath IS NOT NULL
                """, arguments: [cutoff])
        }
        for path in paths {
            try? FileManager.default.removeItem(at: audioDirectory.appending(path: path))
        }
        return try db.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE createdAt < ?", arguments: [cutoff])
            return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
        }
    }

    // MARK: - app styles (§3.7 / plan T10)

    /// Set or replace a per-app style override. `appName` is best-effort
    /// display metadata — pass the localized name when known.
    public func setStyleOverride(bundleID: String, appName: String? = nil,
                                 style: String) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO app_styles (bundleID, appName, style)
                VALUES (?, ?, ?)
                ON CONFLICT(bundleID) DO UPDATE SET
                    appName = COALESCE(excluded.appName, app_styles.appName),
                    style = excluded.style
                """, arguments: [bundleID, appName, style])
        }
    }

    public func removeStyleOverride(bundleID: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM app_styles WHERE bundleID = ?",
                           arguments: [bundleID])
        }
    }

    /// Every user override, bundleID → row.
    public func styleOverrides() throws -> [AppStyleOverride] {
        try db.read { db in
            try Row.fetchAll(db, sql:
                "SELECT bundleID, appName, style FROM app_styles ORDER BY bundleID")
                .map { row in
                    AppStyleOverride(bundleID: row["bundleID"],
                                     appName: row["appName"],
                                     style: row["style"])
                }
        }
    }

    /// bundleID → last-seen display name for every app in dictation history.
    /// Feeds the Styles page's "seen in history" rows.
    public func dictationApps() throws -> [AppStyleOverride] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT appBundleID, appName, MAX(createdAt) FROM dictations
                WHERE appBundleID IS NOT NULL
                GROUP BY appBundleID
                """)
                .map { row in
                    AppStyleOverride(bundleID: row["appBundleID"],
                                     appName: row["appName"],
                                     style: "")
                }
        }
    }

    // MARK: - statistics

    /// Settings → "Reset statistics": clears `stats_daily` only — dictation
    /// history, dictionary and style overrides are untouched.
    public func resetStatistics() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM stats_daily")
        }
    }

    /// Re-derives missing `stats_daily` rows (the v2 migration's backfill),
    /// exposed for tests simulating a pre-aggregation database.
    func backfillDailyStats() throws {
        try db.write { db in try Self.backfillDailyStats(db) }
    }

    // MARK: - read

    public func recent(limit: Int = 5) throws -> [Dictation] {
        try db.read { db in
            try Self.fetchDictations(db, sql: """
                SELECT * FROM dictations ORDER BY createdAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Newest-first; `query` filters on a case-insensitive substring of
    /// cleaned + raw text (spec: history search).
    public func search(_ query: String) throws -> [Dictation] {
        try db.read { db in
            if query.isEmpty {
                return try Self.fetchDictations(db, sql:
                    "SELECT * FROM dictations ORDER BY createdAt DESC")
            }
            return try Self.fetchDictations(db, sql: """
                SELECT * FROM dictations
                WHERE cleanedText LIKE '%' || ? || '%' COLLATE NOCASE
                   OR rawText LIKE '%' || ? || '%' COLLATE NOCASE
                ORDER BY createdAt DESC
                """, arguments: [query, query])
        }
    }

    /// Words dictated per day for the last `days` days (for the heatmap).
    /// Key is the day string "YYYY-MM-DD" in local time.
    public func wordsPerDay(last days: Int, now: Date = Date()) throws -> [String: Int] {
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(days - 1) * 86400))
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT day, words FROM stats_daily WHERE day >= ?
                """, arguments: [cutoff])
            var out: [String: Int] = [:]
            for row in rows { out[row["day"]] = row["words"] }
            return out
        }
    }

    public func stats(typingWPM: Double = 40, now: Date = Date()) throws -> DictationStats {
        try db.read { db in
            var s = DictationStats(typingWPM: typingWPM)
            if let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(words),0) w, COALESCE(SUM(sessions),0) n,
                       COALESCE(SUM(speakingSeconds),0) sec FROM stats_daily
                """) {
                s.totalWords = row["w"]
                s.totalSessions = row["n"]
                s.speakingSeconds = row["sec"]
            }
            if let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(words),0) w, COALESCE(SUM(sessions),0) n
                FROM stats_daily WHERE day = ?
                """, arguments: [Self.dayKey(now)]) {
                s.todayWords = row["w"]
                s.todaySessions = row["n"]
            }
            return s
        }
    }

    // MARK: - helpers

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func fetchDictations(_ db: Database, sql: String,
                                        arguments: StatementArguments = .init()) throws -> [Dictation] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            Dictation(
                id: row["id"],
                createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                durationSec: row["durationSec"],
                appBundleID: row["appBundleID"],
                appName: row["appName"],
                rawText: row["rawText"],
                cleanedText: row["cleanedText"],
                style: row["style"],
                cleanupFallback: row["cleanupFallback"],
                audioPath: row["audioPath"]
            )
        }
    }
}
