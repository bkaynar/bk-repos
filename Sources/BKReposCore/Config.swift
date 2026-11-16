import Foundation

/// `~/Library/Application Support/BKRepos/config.json` dosyasından okunan ayarlar.
/// Dosyada olmayan alanlar varsayılan değerleri alır.
public struct Config: Codable, Sendable, Equatable {
    /// Git depolarının aranacağı klasörler.
    public var roots: [String] = ["~/Documents/GitHub", "~/IdeaProjects"]
    /// Kök klasörün altında kaç seviye derine inileceği (`kök/ad` = 1).
    public var maxDepth: Int = 3
    /// Depo aranırken içine girilmeyen klasör adları. Noktayla başlayan klasörlere de girilmez.
    public var skipDirectories: [String] = [
        "node_modules", "build", "Pods", "DerivedData", "dist", "target", "vendor", "venv", "Carthage", "out",
    ]
    /// Git'in tanımadığı (kopuk) çalışma ağaçlarının aranacağı, depoya göreli klasörler.
    public var worktreeDirectories: [String] = [".claude/worktrees", ".worktrees", "worktrees"]
    /// Push'lanmamış commit bu kadar günden eskiyse Kritik sayılır.
    public var unpushedCriticalDays: Double = 1
    /// Commit'lenmemiş değişiklik bu kadar günden eskiyse Kritik sayılır.
    public var uncommittedCriticalDays: Double = 3
    /// Temiz bir çalışma ağacına bu kadar gündür dokunulmadıysa "kaldırılabilir" uyarısı verilir.
    public var staleWorktreeDays: Double = 14
    /// Günlük hatırlatma açık mı.
    public var reminderEnabled: Bool = true
    /// Günlük hatırlatma saati (SS:DD).
    public var reminderTime: String = "18:00"
    /// Arka planda otomatik taramalar arasındaki dakika.
    public var scanIntervalMinutes: Int = 30
    /// Aynı anda taranan depo sayısı.
    public var parallelism: Int = 4
    /// Listede gösterilmeyecek depo yolları.
    public var ignoredRepos: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? d.maxDepth
        skipDirectories = try c.decodeIfPresent([String].self, forKey: .skipDirectories) ?? d.skipDirectories
        worktreeDirectories = try c.decodeIfPresent([String].self, forKey: .worktreeDirectories) ?? d.worktreeDirectories
        unpushedCriticalDays = try c.decodeIfPresent(Double.self, forKey: .unpushedCriticalDays) ?? d.unpushedCriticalDays
        uncommittedCriticalDays = try c.decodeIfPresent(Double.self, forKey: .uncommittedCriticalDays) ?? d.uncommittedCriticalDays
        staleWorktreeDays = try c.decodeIfPresent(Double.self, forKey: .staleWorktreeDays) ?? d.staleWorktreeDays
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? d.reminderEnabled
        reminderTime = try c.decodeIfPresent(String.self, forKey: .reminderTime) ?? d.reminderTime
        scanIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .scanIntervalMinutes) ?? d.scanIntervalMinutes
        parallelism = try c.decodeIfPresent(Int.self, forKey: .parallelism) ?? d.parallelism
        ignoredRepos = try c.decodeIfPresent([String].self, forKey: .ignoredRepos) ?? d.ignoredRepos
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BKRepos", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Ayar dosyasını okur; bozuksa ya da yoksa varsayılanları kullanır. Dosyayı OLUŞTURMAZ.
    public static func load(from url: URL = fileURL) -> Config {
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        return Config()
    }

    /// Ayar dosyası yoksa varsayılanlarla oluşturur (menüdeki "Ayarlar dosyasını aç" için).
    public static func createFileIfMissing() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(Config()).write(to: url)
    }

    public var expandedRoots: [URL] {
        roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    public var expandedIgnoredRepos: Set<String> {
        Set(ignoredRepos.map { Paths.canonical(($0 as NSString).expandingTildeInPath) })
    }

    /// `reminderTime` değerinin saat ve dakikası; biçim bozuksa 18:00.
    public var reminderHourMinute: (hour: Int, minute: Int) {
        let parts = reminderTime.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) {
            return (h, m)
        }
        return (18, 0)
    }
}

public enum Paths {
    /// Karşılaştırma için tek biçime getirilmiş yol (sembolik bağlantılar çözülür).
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
