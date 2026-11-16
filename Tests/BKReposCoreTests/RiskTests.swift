import XCTest
@testable import BKReposCore

/// Risk sınıflandırması saf bir işlevdir; durumlar elle kurulur.
final class RiskTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// Uzak deposu olan, eşitlenmiş, temiz depo.
    func cleanRepo() -> RepoStatus {
        var repo = RepoStatus(path: "/tmp/proje")
        repo.status.head = .branch("main")
        repo.status.upstream = "origin/main"
        repo.status.ahead = 0
        repo.status.behind = 0
        repo.remotes = [Remote(name: "origin", url: "git@example.com:x/y.git")]
        repo.defaultBranch = "main"
        repo.lastCommit = CommitInfo(date: ago(10), subject: "son")
        var main = BranchInfo(name: "main")
        main.upstream = "origin/main"
        main.isCurrent = true
        main.existsOnRemote = true
        main.worktreePath = "/tmp/proje"
        repo.branches = [main]
        return repo
    }

    func level(_ repo: RepoStatus, _ config: Config = Config()) -> RiskLevel {
        RepoReport(repo: repo, findings: Risk.evaluate(repo, config: config, now: now)).level
    }

    func texts(_ repo: RepoStatus, _ config: Config = Config()) -> [String] {
        Risk.evaluate(repo, config: config, now: now).map(\.text)
    }

    func testCleanRepoHasNoFindings() {
        XCTAssertEqual(level(cleanRepo()), .clean)
        XCTAssertTrue(Risk.evaluate(cleanRepo(), now: now).isEmpty)
    }

    func testNoRemoteWithCommitsIsCritical() {
        var repo = cleanRepo()
        repo.remotes = []
        repo.status.upstream = nil
        XCTAssertEqual(level(repo), .critical)
        XCTAssertEqual(texts(repo).first, "Uzak depo yok: bu projenin tek kopyası bu bilgisayarda")

        // Hiç commit yoksa kaybedilecek commit de yoktur.
        repo.status.isUnborn = true
        repo.branches = []
        XCTAssertEqual(level(repo), .clean)
    }

    func testUnpushedCommitsByAge() {
        var repo = cleanRepo()
        repo.status.ahead = 3
        repo.branches[0].ahead = 3
        repo.branches[0].uniqueCommits = 3
        repo.branches[0].oldestUnique = ago(2.2)
        XCTAssertEqual(level(repo), .critical)
        XCTAssertEqual(texts(repo).first, "3 commit push'lanmamış (2 gündür)")

        repo.branches[0].oldestUnique = ago(0.2)
        XCTAssertEqual(level(repo), .warning)
        XCTAssertEqual(texts(repo).first, "3 commit push'lanmamış (4 saattir)")

        // Eşik ayarlanabilir.
        var config = Config()
        config.unpushedCriticalDays = 0.1
        XCTAssertEqual(level(repo, config), .critical)
        config.unpushedCriticalDays = 5
        repo.branches[0].oldestUnique = ago(2.2)
        XCTAssertEqual(level(repo, config), .warning)
    }

    func testUncommittedChangesByAge() {
        var repo = cleanRepo()
        repo.status.unstaged = 2
        repo.status.untracked = 1
        repo.status.changedPaths = ["a", "b", "c"]
        repo.oldestChange = ago(4)
        XCTAssertEqual(level(repo), .critical)
        XCTAssertEqual(texts(repo).first, "3 dosyada commit'lenmemiş değişiklik (en eskisi 4 gündür)")

        repo.oldestChange = ago(1)
        XCTAssertEqual(level(repo), .warning)

        var config = Config()
        config.uncommittedCriticalDays = 0.5
        XCTAssertEqual(level(repo, config), .critical)

        // Yalnızca silinmiş dosyalar varsa tarih bilinmez; uyarı düzeyinde kalır.
        repo.oldestChange = nil
        XCTAssertEqual(level(repo), .warning)
    }

    func testBranchThatExistsOnNoRemoteIsCriticalRegardlessOfAge() {
        var repo = cleanRepo()
        var local = BranchInfo(name: "deneme")
        local.uniqueCommits = 2
        local.oldestUnique = ago(0.01)
        repo.branches.append(local)
        XCTAssertEqual(level(repo), .critical)
        XCTAssertTrue(texts(repo)[0].hasPrefix("‘deneme’ dalı hiçbir uzak depoda yok: 2 commit yalnızca bu bilgisayarda"))

        // Benzersiz commit'i olmayan yerel dal risk değildir.
        repo.branches[1].uniqueCommits = 0
        XCTAssertEqual(level(repo), .clean)

        // Upstream'i silinmiş dal da uzak depoda yok sayılır.
        repo.branches[1].uniqueCommits = 1
        repo.branches[1].upstream = "origin/deneme"
        repo.branches[1].upstreamGone = true
        XCTAssertEqual(level(repo), .critical)
    }

    func testUniqueCommitsOnBranchMergedIntoDefaultAreReportedOnDefaultOnly() {
        var repo = cleanRepo()
        repo.branches[0].uniqueCommits = 1
        repo.branches[0].oldestUnique = ago(0.1)
        var merged = BranchInfo(name: "bitti")
        merged.uniqueCommits = 1
        merged.oldestUnique = ago(0.1)
        merged.mergedIntoDefault = true
        repo.branches.append(merged)
        let findings = Risk.evaluate(repo, now: now)
        XCTAssertEqual(findings.filter { $0.level == .critical }.count, 0)
        XCTAssertTrue(findings.contains { $0.text.hasPrefix("1 commit push'lanmamış") })
        XCTAssertTrue(findings.contains { $0.text == "1 dal main dalına birleştirilmiş, silinebilir: bitti" })
    }

    func testStashAndMergedBranchesAreWarnings() {
        var repo = cleanRepo()
        repo.stashCount = 2
        repo.oldestStash = ago(12)
        XCTAssertEqual(level(repo), .warning)
        XCTAssertEqual(texts(repo), ["2 stash var (en eskisi 12 gün önce)"])

        repo.stashCount = 0
        var merged = BranchInfo(name: "eski-is")
        merged.mergedIntoDefault = true
        var inWorktree = BranchInfo(name: "acik")
        inWorktree.mergedIntoDefault = true
        inWorktree.worktreePath = "/tmp/wt"
        repo.branches += [merged, inWorktree]
        XCTAssertEqual(level(repo), .warning)
        XCTAssertEqual(Risk.deletableBranches(repo).map(\.name), ["eski-is"])
    }

    func testDeletableBranchesNeverIncludeCurrentOrDefault() {
        var repo = cleanRepo()
        repo.branches[0].mergedIntoDefault = true // savunma amaçlı: varsayılan dal işaretlense bile
        var current = BranchInfo(name: "is")
        current.mergedIntoDefault = true
        current.isCurrent = true
        repo.branches[0].isCurrent = false
        repo.branches.append(current)
        XCTAssertTrue(Risk.deletableBranches(repo).isEmpty)
    }

    func testWorktreeFindings() {
        var repo = cleanRepo()
        var stale = WorktreeInfo(path: "/tmp/proje/.claude/worktrees/ajan")
        stale.branch = "ajan"
        stale.status = WorkingTreeStatus()
        stale.lastActivity = ago(20)
        repo.worktrees = [stale]
        XCTAssertEqual(level(repo), .warning)
        XCTAssertEqual(texts(repo), ["Çalışma ağacı ‘ajan’ temiz ve 20 gündür dokunulmamış; kaldırılabilir"])

        // Yeni ve temiz çalışma ağacı risk değildir.
        repo.worktrees[0].lastActivity = ago(1)
        XCTAssertEqual(level(repo), .clean)

        // Kirli çalışma ağacı, depo gibi yaşa göre sınıflanır.
        repo.worktrees[0].status?.untracked = 1
        repo.worktrees[0].status?.changedPaths = ["yeni.txt"]
        repo.worktrees[0].oldestChange = ago(5)
        XCTAssertEqual(level(repo), .critical)
        repo.worktrees[0].oldestChange = ago(0.5)
        XCTAssertEqual(level(repo), .warning)

        var orphan = WorktreeInfo(path: "/tmp/proje/.claude/worktrees/kopuk")
        orphan.isOrphaned = true
        orphan.orphanPointer = "/yok/.git/worktrees/kopuk"
        repo.worktrees = [orphan]
        XCTAssertEqual(level(repo), .warning)
        XCTAssertTrue(texts(repo)[0].hasPrefix("Kopuk çalışma ağacı ‘kopuk’"))

        var detached = WorktreeInfo(path: "/tmp/wt")
        detached.status = WorkingTreeStatus()
        detached.isDetached = true
        detached.danglingCommits = 2
        repo.worktrees = [detached]
        XCTAssertEqual(level(repo), .critical)
    }

    func testDetachedHeadWithDanglingCommitsIsCritical() {
        var repo = cleanRepo()
        repo.status.head = .detached("abc1234")
        repo.status.upstream = nil
        repo.branches[0].isCurrent = false
        XCTAssertEqual(level(repo), .clean)
        repo.danglingCommits = 1
        XCTAssertEqual(level(repo), .critical)
    }

    func testFindingsAndReportsAreSortedByRisk() {
        var repo = cleanRepo()
        repo.stashCount = 1
        repo.status.behind = 2
        repo.branches[0].behind = 2
        repo.status.untracked = 1
        repo.status.changedPaths = ["a"]
        repo.oldestChange = ago(9)
        XCTAssertEqual(Risk.evaluate(repo, now: now).map(\.level), [.critical, .warning, .clean])

        var warning = cleanRepo()
        warning.path = "/tmp/b-uyari"
        warning.stashCount = 1
        var clean = cleanRepo()
        clean.path = "/tmp/a-temiz"
        repo.path = "/tmp/z-kritik"
        let reports = [clean, warning, repo].map { RepoReport(repo: $0, findings: Risk.evaluate($0, now: now)) }
        XCTAssertEqual(RepoScanner.sorted(reports).map(\.repo.name), ["z-kritik", "b-uyari", "a-temiz"])
    }

    func testScanErrorIsReported() {
        var repo = RepoStatus(path: "/tmp/bozuk")
        repo.scanError = "fatal: not a git repository"
        XCTAssertEqual(level(repo), .warning)
        XCTAssertEqual(texts(repo), ["Depo taranamadı"])
    }
}
