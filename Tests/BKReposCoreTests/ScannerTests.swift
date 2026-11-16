import XCTest
@testable import BKReposCore

/// Tarayıcıyı geçici klasörde kurulan gerçek git depolarına karşı dener.
final class ScannerTests: TempRepoTestCase {
    func testSyncedRepoIsClean() throws {
        let (repo, _) = try makeRepoWithRemote("temiz")
        let status = RepoScanner.scan(path: repo)
        XCTAssertNil(status.scanError)
        XCTAssertEqual(status.status.head, .branch("main"))
        XCTAssertEqual(status.status.upstream, "origin/main")
        XCTAssertEqual(status.status.ahead, 0)
        XCTAssertEqual(status.status.behind, 0)
        XCTAssertEqual(status.remotes.map(\.name), ["origin"])
        XCTAssertEqual(status.lastCommit?.subject, "ilk commit")
        XCTAssertEqual(status.defaultBranch, "main")
        XCTAssertEqual(status.branches.map(\.name), ["main"])
        XCTAssertTrue(status.branches[0].existsOnRemote)
        XCTAssertEqual(status.branches[0].uniqueCommits, 0)
        XCTAssertTrue(status.worktrees.isEmpty)
        XCTAssertEqual(levels(status), .clean)
    }

    func testRepoWithoutRemoteIsCriticalAndUnbornRepoIsNot() throws {
        let repo = try makeRepo("uzaksiz")
        let status = RepoScanner.scan(path: repo)
        XCTAssertTrue(status.remotes.isEmpty)
        XCTAssertEqual(levels(status), .critical)

        let empty = try makeDirectory("bos")
        try git("init", "-q", "-b", "main", in: empty)
        let unborn = RepoScanner.scan(path: empty)
        XCTAssertNil(unborn.scanError)
        XCTAssertFalse(unborn.hasCommits)
        XCTAssertEqual(levels(unborn), .clean)
    }

    func testAheadAndBehindFromLocalRefs() throws {
        let (repo, remote) = try makeRepoWithRemote("ileri")
        try commit("yerel bir", in: repo, date: daysAgo(2))
        try commit("yerel iki", in: repo)
        var status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.status.ahead, 2)
        XCTAssertEqual(status.status.behind, 0)
        XCTAssertEqual(status.unpushedCommits.map(\.subject), ["yerel iki", "yerel bir"])
        XCTAssertEqual(status.branches[0].uniqueCommits, 2)
        XCTAssertEqual(levels(status), .critical) // en eski commit 2 günlük
        XCTAssertTrue(Risk.evaluate(status).contains { $0.text == "2 commit push'lanmamış (2 gündür)" })

        // Başka bir kopya uzak depoya commit gönderir.
        let other = try makeDirectory("diger")
        try git("clone", "-q", remote, other, in: root)
        try commit("uzaktan", file: "uzak.txt", in: other)
        try git("push", "-q", in: other)

        // Tarama fetch yapmaz: uzak depo ilerlese de yerel bilgi değişmez.
        status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.status.behind, 0)

        // Kullanıcı getirdikten sonra (testte elle) geride olduğu görülür.
        try git("fetch", "-q", in: repo)
        status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.status.ahead, 2)
        XCTAssertEqual(status.status.behind, 1)
    }

    func testWorkingTreeCountsAndOldestChange() throws {
        let (repo, _) = try makeRepoWithRemote("degisik")
        try commit("ikinci", file: "b.txt", in: repo)
        try git("push", "-q", in: repo)
        try write("hazır", to: "hazir.txt", in: repo)
        try git("add", "hazir.txt", in: repo)
        try write("değişti", to: "b.txt", in: repo, modified: daysAgo(5))
        try write("yeni", to: "boşluklu ad.txt", in: repo, modified: daysAgo(1))

        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.status.staged, 1)
        XCTAssertEqual(status.status.unstaged, 1)
        XCTAssertEqual(status.status.untracked, 1)
        XCTAssertEqual(Set(status.status.changedPaths), ["hazir.txt", "b.txt", "boşluklu ad.txt"])
        let age = try XCTUnwrap(status.oldestChange).timeIntervalSinceNow / -86_400
        XCTAssertEqual(age, 5, accuracy: 0.01)
        XCTAssertEqual(levels(status), .critical)

        var patient = Config()
        patient.uncommittedCriticalDays = 10
        XCTAssertEqual(levels(status, config: patient), .warning)
    }

    func testStatusDoesNotLeaveIndexLock() throws {
        let repo = try makeRepo("kilit")
        try write("x", to: "dosya.txt", in: repo)
        _ = RepoScanner.scan(path: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/index.lock"))
    }

    func testStashes() throws {
        let (repo, _) = try makeRepoWithRemote("stash")
        try write("bir", to: "dosya.txt", in: repo)
        try git("stash", "-q", in: repo)
        try write("iki", to: "dosya.txt", in: repo)
        try git("stash", "-q", in: repo)
        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.stashCount, 2)
        XCTAssertNotNil(status.oldestStash)
        XCTAssertFalse(status.status.isDirty)
        XCTAssertEqual(levels(status), .warning)
    }

    func testLocalOnlyMergedAndPushedBranches() throws {
        let (repo, _) = try makeRepoWithRemote("dallar")

        // Yalnızca yerelde olan, benzersiz commit'li dal.
        try git("switch", "-q", "-c", "yerel-is", in: repo)
        try commit("yalnızca yerelde", file: "y.txt", in: repo)

        // Push'lanmış ama birleştirilmemiş dal.
        try git("switch", "-q", "-c", "uzakta", "main", in: repo)
        try commit("uzakta da var", file: "u.txt", in: repo)
        try git("push", "-q", "-u", "origin", "uzakta", in: repo)

        // main'e birleştirilmiş dal.
        try git("switch", "-q", "-c", "bitti", "main", in: repo)
        try commit("biten iş", file: "b.txt", in: repo)
        try git("switch", "-q", "main", in: repo)
        try git("merge", "-q", "--no-ff", "-m", "birleştir", "bitti", in: repo)
        try git("push", "-q", in: repo)

        let status = RepoScanner.scan(path: repo)
        let byName = Dictionary(uniqueKeysWithValues: status.branches.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["main", "yerel-is", "uzakta", "bitti"])

        XCTAssertEqual(byName["yerel-is"]?.uniqueCommits, 1)
        XCTAssertEqual(byName["yerel-is"]?.existsOnRemote, false)
        XCTAssertEqual(byName["yerel-is"]?.mergedIntoDefault, false)

        XCTAssertEqual(byName["uzakta"]?.uniqueCommits, 0)
        XCTAssertEqual(byName["uzakta"]?.existsOnRemote, true)
        XCTAssertEqual(byName["uzakta"]?.mergedIntoDefault, false)

        XCTAssertEqual(byName["bitti"]?.mergedIntoDefault, true)
        XCTAssertEqual(byName["bitti"]?.uniqueCommits, 0)
        XCTAssertEqual(byName["main"]?.mergedIntoDefault, false)
        XCTAssertEqual(byName["main"]?.isCurrent, true)

        XCTAssertEqual(Risk.deletableBranches(status).map(\.name), ["bitti"])
        XCTAssertEqual(levels(status), .critical)
        XCTAssertTrue(Risk.evaluate(status).contains { $0.level == .critical && $0.text.contains("‘yerel-is’ dalı hiçbir uzak depoda yok") })
    }

    func testDetachedHeadWithDanglingCommits() throws {
        let (repo, _) = try makeRepoWithRemote("ayrik")
        try git("switch", "-q", "--detach", in: repo)
        var status = RepoScanner.scan(path: repo)
        XCTAssertNil(status.status.head.branchName)
        XCTAssertEqual(status.danglingCommits, 0)
        XCTAssertEqual(levels(status), .clean)

        try commit("sahipsiz", in: repo)
        status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.danglingCommits, 1)
        XCTAssertEqual(levels(status), .critical)
    }

    func testLinkedWorktreesBelongToTheirRepo() throws {
        let (repo, _) = try makeRepoWithRemote("agacli")
        let clean = repo + "/.claude/worktrees/temiz-ajan"
        let dirty = repo + "/.claude/worktrees/kirli ajan"
        try git("worktree", "add", "-q", "-b", "ajan/temiz", clean, in: repo)
        try git("worktree", "add", "-q", "-b", "ajan/kirli", dirty, in: repo)
        try write("yarım iş", to: "yarim.txt", in: dirty, modified: daysAgo(4))
        try write("gizli", to: ".env", in: clean)
        try write(".env\n", to: ".git/info/exclude", in: repo)

        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.worktrees.map(\.name), ["kirli ajan", "temiz-ajan"])
        let dirtyInfo = try XCTUnwrap(status.worktrees.first { $0.name == "kirli ajan" })
        let cleanInfo = try XCTUnwrap(status.worktrees.first { $0.name == "temiz-ajan" })
        XCTAssertEqual(dirtyInfo.branch, "ajan/kirli")
        XCTAssertTrue(dirtyInfo.isDirty)
        XCTAssertEqual(dirtyInfo.status?.untracked, 1)
        XCTAssertNotNil(dirtyInfo.oldestChange)
        XCTAssertFalse(cleanInfo.isDirty)
        XCTAssertEqual(cleanInfo.status?.ignoredPaths, [".env"])
        XCTAssertNotNil(cleanInfo.lastActivity)
        XCTAssertFalse(cleanInfo.isOrphaned)

        // Dalların hangi çalışma ağacında açık olduğu bilinir; bu dallar silinebilir sayılmaz.
        let branch = try XCTUnwrap(status.branches.first { $0.name == "ajan/temiz" })
        XCTAssertEqual(branch.worktreePath.map(Paths.canonical), Paths.canonical(clean))
        XCTAssertTrue(branch.mergedIntoDefault)
        XCTAssertTrue(Risk.deletableBranches(status).isEmpty)

        // Kirli çalışma ağacı 4 gündür bekliyor: Kritik.
        XCTAssertEqual(levels(status), .critical)

        // Uzun süredir dokunulmamış temiz çalışma ağacı uyarıdır.
        var impatient = Config()
        impatient.staleWorktreeDays = 0
        XCTAssertTrue(Risk.evaluate(status, config: impatient).contains {
            $0.level == .warning && $0.text.hasPrefix("Çalışma ağacı ‘temiz-ajan’ temiz ve")
        })
    }

    func testOrphanedAndPrunableWorktrees() throws {
        let (repo, _) = try makeRepoWithRemote("kopuklu")
        // Başka bir bilgisayardan kopyalanmış gibi: `.git` dosyası var ama gösterdiği yer yok.
        try write("gitdir: /Users/baskasi/proje/.git/worktrees/ajan-1\n", to: ".claude/worktrees/ajan-1/.git", in: repo)
        try write("içerik", to: ".claude/worktrees/ajan-1/dosya.txt", in: repo)
        // Kayıtlı ama klasörü silinmiş çalışma ağacı.
        let gone = root + "/silinen"
        try git("worktree", "add", "-q", "-b", "silinen", gone, in: repo)
        try FileManager.default.removeItem(atPath: gone)

        let status = RepoScanner.scan(path: repo)
        let orphan = try XCTUnwrap(status.worktrees.first { $0.name == "ajan-1" })
        XCTAssertTrue(orphan.isOrphaned)
        XCTAssertEqual(orphan.orphanPointer, "/Users/baskasi/proje/.git/worktrees/ajan-1")
        XCTAssertNotNil(orphan.lastActivity)
        let prunable = try XCTUnwrap(status.worktrees.first { $0.name == "silinen" })
        XCTAssertTrue(prunable.isPrunable)
        XCTAssertNil(status.scanError)
    }

    func testDiscoveryDepthSkipsAndWorktrees() throws {
        let (top, _) = try makeRepoWithRemote("kok/ust")
        _ = try makeRepo("kok/grup/ic")                    // derinlik 2
        _ = try makeRepo("kok/grup/alt/derin")             // derinlik 3
        _ = try makeRepo("kok/grup/alt/cok/derin")         // derinlik 4: bulunmaz
        _ = try makeRepo("kok/ust/node_modules/paket")     // atlanır
        _ = try makeRepo("kok/ust/build/cikti")            // atlanır
        _ = try makeRepo("kok/ust/.build/checkouts/x")     // noktalı klasör: atlanır
        _ = try makeRepo("kok/ust/araclar/ic-depo")        // depo içindeki bağımsız depo
        _ = try makeRepo("kok/yoksay")
        _ = try makeDirectory("kok/depo-degil")
        // Kök altında duran bağlı çalışma ağacı: ayrı depo sayılmaz.
        try git("worktree", "add", "-q", "-b", "yan", root + "/kok/ust-yan", in: top)
        // Ana deposu köklerin dışında olan çalışma ağacı: ana depo listeye eklenir.
        let outside = try makeRepo("disarida/ana")
        try git("worktree", "add", "-q", "-b", "yan", root + "/kok/disaridan-gelen", in: outside)

        var config = Config()
        config.roots = [root + "/kok", root + "/olmayan-klasor"]
        config.ignoredRepos = [root + "/kok/yoksay"]
        let found = Discovery.find(config: config)
        let names = Set(found.repos.map { String($0.dropFirst(root.count + 1)) })
        XCTAssertEqual(names, ["kok/ust", "kok/grup/ic", "kok/grup/alt/derin", "kok/ust/araclar/ic-depo", "disarida/ana"])
        XCTAssertTrue(found.orphans.isEmpty)

        let progress = ProgressRecorder()
        let reports = RepoScanner.scanAll(config: config) { done, total, _ in progress.record(done, total) }
        XCTAssertEqual(reports.count, 5)
        XCTAssertEqual(progress.calls, 5)
        XCTAssertEqual(progress.lastTotal, 5)
        // Riske göre sıralı: uzak deposu olmayanlar (Kritik) önce.
        XCTAssertEqual(reports.map(\.level), reports.map(\.level).sorted(by: >))
        XCTAssertEqual(reports.last?.repo.name, "ust")
        let topReport = try XCTUnwrap(reports.first { $0.repo.name == "ust" })
        XCTAssertEqual(topReport.repo.worktrees.map(\.name), ["ust-yan"])
    }

    func testOrphanOutsideKnownFoldersIsAttachedToEnclosingRepo() throws {
        let (repo, _) = try makeRepoWithRemote("kok/proje")
        try write("gitdir: /yok/.git/worktrees/w\n", to: "kopya/.git", in: repo)
        var config = Config()
        config.roots = [root + "/kok"]
        let found = Discovery.find(config: config)
        XCTAssertEqual(found.orphans.count, 1)
        let reports = RepoScanner.scanAll(config: config)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].repo.worktrees.map(\.name), ["kopya"])
        XCTAssertEqual(reports[0].repo.worktrees.first?.isOrphaned, true)
    }

    func testBrokenRepositoryReportsScanError() throws {
        let path = try makeDirectory("bozuk")
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        let status = RepoScanner.scan(path: path)
        XCTAssertNotNil(status.scanError)
        XCTAssertEqual(levels(status), .warning)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var lastTotal = 0

    func record(_ done: Int, _ total: Int) {
        lock.lock()
        calls += 1
        lastTotal = total
        lock.unlock()
    }
}
