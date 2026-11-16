import Foundation

public enum RiskLevel: Int, Comparable, CaseIterable, Sendable {
    case clean = 0
    case warning = 1
    case critical = 2

    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .critical: return "Kritik"
        case .warning: return "Uyarı"
        case .clean: return "Temiz"
        }
    }
}

public struct CommitInfo: Equatable, Sendable {
    public var date: Date
    public var subject: String

    public init(date: Date, subject: String) {
        self.date = date
        self.subject = subject
    }
}

public struct Remote: Equatable, Sendable {
    public var name: String
    public var url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

public enum HeadState: Equatable, Sendable {
    case branch(String)
    /// HEAD bir dala bağlı değil; kısa commit kimliği.
    case detached(String)

    public var branchName: String? {
        if case .branch(let name) = self { return name }
        return nil
    }
}

/// `git status --porcelain=v2 --branch` çıktısının özeti.
public struct WorkingTreeStatus: Equatable, Sendable {
    public var head: HeadState = .detached("")
    /// Henüz hiç commit yok.
    public var isUnborn = false
    public var upstream: String?
    /// Upstream tanımlı ve yerelde karşılığı var (ahead/behind hesaplanabildi).
    public var ahead: Int?
    public var behind: Int?
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0
    /// Değişen ya da izlenmeyen dosyaların depoya göreli yolları.
    public var changedPaths: [String] = []
    public var ignoredPaths: [String] = []

    public init() {}

    /// Değişen dosya sayısı (aynı dosya hem hazırlanmış hem değişmiş olabilir; bir kez sayılır).
    public var changeCount: Int { changedPaths.count }
    public var isDirty: Bool { changeCount > 0 }
    /// Upstream ayarlı ama uzak dal artık yok (`[gone]`).
    public var upstreamGone: Bool { upstream != nil && ahead == nil }
}

public struct BranchInfo: Equatable, Sendable, Identifiable {
    public var name: String
    public var upstream: String?
    public var upstreamGone = false
    public var ahead = 0
    public var behind = 0
    public var lastCommit: Date?
    public var isCurrent = false
    /// Bu dal bağlı bir çalışma ağacında açıksa onun yolu.
    public var worktreePath: String?
    /// Hiçbir uzak depoda bulunmayan commit sayısı (`git log <dal> --not --remotes`).
    public var uniqueCommits = 0
    public var oldestUnique: Date?
    /// Dalın bir uzak karşılığı var (upstream'i duruyor ya da aynı adda uzak dal var).
    public var existsOnRemote = false
    /// Varsayılan dala birleştirilmiş.
    public var mergedIntoDefault = false

    public var id: String { name }

    public init(name: String) { self.name = name }
}

public struct WorktreeInfo: Equatable, Sendable, Identifiable {
    public var path: String
    public var branch: String?
    public var head: String = ""
    public var isMain = false
    public var isDetached = false
    public var isBare = false
    public var isLocked = false
    /// Git'e kayıtlı ama klasörü yok.
    public var isPrunable = false
    /// Klasör duruyor ama git onu tanımıyor (`.git` dosyasının gösterdiği yer yok).
    public var isOrphaned = false
    public var orphanPointer: String?
    public var status: WorkingTreeStatus?
    public var oldestChange: Date?
    public var lastActivity: Date?
    /// Ayrık HEAD'de olup hiçbir dalda ve uzak depoda bulunmayan commit sayısı.
    public var danglingCommits = 0
    public var scanError: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var isDirty: Bool { status?.isDirty ?? false }

    public init(path: String) { self.path = path }
}

/// Bir deponun taranan durumu. Yalnızca salt okunur git komutlarıyla doldurulur.
public struct RepoStatus: Equatable, Sendable, Identifiable {
    public var path: String
    public var status = WorkingTreeStatus()
    public var oldestChange: Date?
    public var newestChange: Date?
    public var stashCount = 0
    public var oldestStash: Date?
    public var lastCommit: CommitInfo?
    public var remotes: [Remote] = []
    public var defaultBranch: String?
    public var branches: [BranchInfo] = []
    /// Ana çalışma ağacı dışındaki çalışma ağaçları.
    public var worktrees: [WorktreeInfo] = []
    /// Geçerli dalın upstream'inde olmayan commit'ler (push onayında listelenir), yeniden eskiye.
    public var unpushedCommits: [CommitInfo] = []
    /// Ana çalışma ağacı ayrık HEAD'deyse hiçbir dalda ve uzak depoda olmayan commit sayısı.
    public var danglingCommits = 0
    public var scanError: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var hasCommits: Bool { !status.isUnborn }
    public var currentBranch: BranchInfo? { branches.first(where: \.isCurrent) }

    public init(path: String) { self.path = path }
}

public struct Finding: Equatable, Sendable, Identifiable {
    public var level: RiskLevel
    public var text: String
    public var detail: String?

    public var id: String { text }

    public init(_ level: RiskLevel, _ text: String, detail: String? = nil) {
        self.level = level
        self.text = text
        self.detail = detail
    }
}

/// Tarama sonucu + risk değerlendirmesi.
public struct RepoReport: Equatable, Sendable, Identifiable {
    public var repo: RepoStatus
    /// Riske göre sıralı bulgular. `.clean` düzeyindekiler yalnızca bilgidir.
    public var findings: [Finding]

    public var id: String { repo.path }
    public var level: RiskLevel { findings.map(\.level).max() ?? .clean }

    public init(repo: RepoStatus, findings: [Finding]) {
        self.repo = repo
        self.findings = findings
    }
}
