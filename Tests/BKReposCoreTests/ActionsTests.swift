import XCTest
@testable import BKReposCore

/// İşlemlerin ön koşulları: hem saf denetim hem de geçici depolarda gerçek çalıştırma.
final class ActionsTests: TempRepoTestCase {
    // MARK: Push

    func testPushRequiresUpstreamAheadAndNotBehind() throws {
        let (repo, remote) = try makeRepoWithRemote("push")
        // Push'lanacak bir şey yok.
        XCTAssertEqual(Actions.blocker(.push, repo: RepoScanner.scan(path: repo)), "Push'lanacak commit yok.")
        XCTAssertFalse(Actions.perform(.push, repoPath: repo).succeeded)

        try commit("gönderilecek", in: repo)
        let ahead = RepoScanner.scan(path: repo)
        XCTAssertNil(Actions.blocker(.push, repo: ahead))
        let confirmation = Actions.confirmation(.push, repo: ahead)
        XCTAssertEqual(confirmation.title, "1 commit origin/main dalına push'lansın mı?")
        XCTAssertTrue(confirmation.message.contains("• gönderilecek"))

        let result = Actions.perform(.push, repoPath: repo)
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(try git("log", "-1", "--format=%s", "main", in: remote), "gönderilecek\n")
        XCTAssertEqual(RepoScanner.scan(path: repo).status.ahead, 0)
    }

    func testPushIsRefusedWhenBehindAndNeverForced() throws {
        let (repo, remote) = try makeRepoWithRemote("geride")
        let other = try makeDirectory("diger")
        try git("clone", "-q", remote, other, in: root)
        try commit("uzaktaki iş", file: "uzak.txt", in: other)
        try git("push", "-q", in: other)
        try commit("yerel iş", in: repo)

        // Yerel bilgi eski: uygulama geride olduğunu bilmiyor, push'u dener; git reddeder ve hata gösterilir.
        let rejected = Actions.perform(.push, repoPath: repo)
        XCTAssertFalse(rejected.succeeded)
        XCTAssertTrue(rejected.message.contains("rejected") || rejected.message.contains("fetch first"), rejected.message)
        XCTAssertEqual(try git("log", "-1", "--format=%s", "main", in: remote), "uzaktaki iş\n")

        // Getirdikten sonra ön koşul push'u baştan engeller.
        XCTAssertTrue(Actions.perform(.fetch, repoPath: repo).succeeded)
        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.status.behind, 1)
        XCTAssertTrue(try XCTUnwrap(Actions.blocker(.push, repo: status)).hasPrefix("Uzak dal 1 commit ileride"))
        XCTAssertFalse(Actions.perform(.push, repoPath: repo).succeeded)
        XCTAssertEqual(try git("log", "-1", "--format=%s", "main", in: remote), "uzaktaki iş\n")
    }

    func testPushBlockersWithoutUpstreamOrBranch() throws {
        let (repo, _) = try makeRepoWithRemote("upstreamsiz")
        try git("switch", "-q", "-c", "yeni", in: repo)
        try commit("yeni iş", in: repo)
        XCTAssertTrue(try XCTUnwrap(Actions.blocker(.push, repo: RepoScanner.scan(path: repo))).contains("upstream'i yok"))
        XCTAssertFalse(Actions.perform(.push, repoPath: repo).succeeded)

        try git("switch", "-q", "--detach", in: repo)
        XCTAssertEqual(Actions.blocker(.push, repo: RepoScanner.scan(path: repo)), "HEAD bir dala bağlı değil.")

        let lonely = try makeRepo("uzaksiz")
        XCTAssertNotNil(Actions.blocker(.push, repo: RepoScanner.scan(path: lonely)))
        XCTAssertEqual(Actions.blocker(.fetch, repo: RepoScanner.scan(path: lonely)), "Uzak depo tanımlı değil.")
        XCTAssertFalse(Actions.perform(.fetch, repoPath: lonely).succeeded)
    }

    func testFetchUpdatesBehindCount() throws {
        let (repo, remote) = try makeRepoWithRemote("getir")
        let other = try makeDirectory("diger")
        try git("clone", "-q", remote, other, in: root)
        try commit("uzaktan", file: "uzak.txt", in: other)
        try git("push", "-q", in: other)
        XCTAssertEqual(RepoScanner.scan(path: repo).status.behind, 0)
        XCTAssertTrue(Actions.perform(.fetch, repoPath: repo).succeeded)
        XCTAssertEqual(RepoScanner.scan(path: repo).status.behind, 1)
    }

    // MARK: Çalışma ağacı

    func testCleanWorktreeIsRemovedAndDirtyOneIsNot() throws {
        let (repo, _) = try makeRepoWithRemote("agac")
        let clean = root + "/temiz-agac"
        let dirty = root + "/kirli-agac"
        try git("worktree", "add", "-q", "-b", "temiz", clean, in: repo)
        try git("worktree", "add", "-q", "-b", "kirli", dirty, in: repo)
        try write("kaydedilmemiş", to: "taslak.txt", in: dirty)

        let status = RepoScanner.scan(path: repo)
        XCTAssertNil(Actions.blocker(.removeWorktree(path: clean), repo: status))
        let reason = try XCTUnwrap(Actions.blocker(.removeWorktree(path: dirty), repo: status))
        XCTAssertTrue(reason.contains("1 dosyada commit'lenmemiş değişiklik var (taslak.txt)"), reason)

        let refused = Actions.perform(.removeWorktree(path: dirty), repoPath: repo)
        XCTAssertFalse(refused.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty + "/taslak.txt"))

        let removed = Actions.perform(.removeWorktree(path: clean), repoPath: repo)
        XCTAssertTrue(removed.succeeded, removed.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean))
        // Dal silinmez, yalnızca klasör kaldırılır.
        XCTAssertTrue(branchExists("temiz", in: repo))
        XCTAssertEqual(RepoScanner.scan(path: repo).worktrees.map(\.name), ["kirli-agac"])
    }

    func testWorktreeThatBecomesDirtyAfterScanIsNotRemoved() throws {
        let (repo, _) = try makeRepoWithRemote("yaris")
        let path = root + "/agac"
        try git("worktree", "add", "-q", "-b", "is", path, in: repo)
        let before = RepoScanner.scan(path: repo)
        XCTAssertNil(Actions.blocker(.removeWorktree(path: path), repo: before))

        // Onay penceresi açıkken dosya değişir: işlem çalışmadan hemen önce yeniden denetlenir.
        try write("son anda", to: "yeni.txt", in: path)
        let result = Actions.perform(.removeWorktree(path: path), repoPath: repo)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.hasPrefix("İşlem yapılmadı:"), result.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/yeni.txt"))
    }

    func testWorktreeRemovalBlockers() throws {
        let (repo, _) = try makeRepoWithRemote("engel")
        let locked = root + "/kilitli"
        try git("worktree", "add", "-q", "-b", "kilitli", locked, in: repo)
        try git("worktree", "lock", locked, in: repo)
        let detached = root + "/ayrik"
        try git("worktree", "add", "-q", "--detach", detached, in: repo)
        try commit("sahipsiz", in: detached)
        try write("gitdir: /yok/.git/worktrees/k\n", to: ".claude/worktrees/kopuk/.git", in: repo)

        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(Actions.blocker(.removeWorktree(path: repo), repo: status), "Ana çalışma ağacı kaldırılamaz.")
        XCTAssertEqual(Actions.blocker(.removeWorktree(path: root + "/baska"), repo: status), "Bu çalışma ağacı artık kayıtlı değil.")
        XCTAssertTrue(try XCTUnwrap(Actions.blocker(.removeWorktree(path: locked), repo: status)).contains("kilitli"))
        XCTAssertTrue(try XCTUnwrap(Actions.blocker(.removeWorktree(path: detached), repo: status)).contains("hiçbir dalda yok"))
        XCTAssertTrue(try XCTUnwrap(
            Actions.blocker(.removeWorktree(path: repo + "/.claude/worktrees/kopuk"), repo: status)
        ).contains("tanımıyor"))

        for path in [repo, locked, detached, repo + "/.claude/worktrees/kopuk"] {
            XCTAssertFalse(Actions.perform(.removeWorktree(path: path), repoPath: repo).succeeded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    func testWorktreeConfirmationListsIgnoredFilesAndUnpushedBranch() throws {
        let (repo, _) = try makeRepoWithRemote("onay")
        try write(".env\n", to: ".git/info/exclude", in: repo)
        let path = root + "/agac"
        try git("worktree", "add", "-q", "-b", "is", path, in: repo)
        try commit("push'lanmamış", in: path)
        try write("SIR=1", to: ".env", in: path)
        let status = RepoScanner.scan(path: repo)
        XCTAssertNil(Actions.blocker(.removeWorktree(path: path), repo: status))
        let message = Actions.confirmation(.removeWorktree(path: path), repo: status).message
        XCTAssertTrue(message.contains("‘is’ dalı silinmez"), message)
        XCTAssertTrue(message.contains("1 commit henüz hiçbir uzak depoda yok"), message)
        XCTAssertTrue(message.contains("yok saydığı 1 öğe de klasörle birlikte silinir: .env"), message)
    }

    // MARK: Dal silme

    func testOnlyMergedBranchesAreDeleted() throws {
        let (repo, _) = try makeRepoWithRemote("dal")
        try git("switch", "-q", "-c", "bitti", in: repo)
        try commit("biten", file: "b.txt", in: repo)
        try git("switch", "-q", "main", in: repo)
        try git("merge", "-q", "bitti", in: repo)
        try git("switch", "-q", "-c", "yarim", in: repo)
        try commit("yarım", file: "y.txt", in: repo)
        try git("switch", "-q", "main", in: repo)
        try git("switch", "-q", "-c", "agacta", in: repo)
        try git("switch", "-q", "main", in: repo)
        try git("worktree", "add", "-q", root + "/agac", "agacta", in: repo)

        let status = RepoScanner.scan(path: repo)
        XCTAssertNil(Actions.blocker(.deleteBranch(name: "bitti"), repo: status))
        XCTAssertEqual(Actions.blocker(.deleteBranch(name: "yarim"), repo: status), "‘yarim’ dalı main dalına birleştirilmemiş.")
        XCTAssertEqual(Actions.blocker(.deleteBranch(name: "main"), repo: status), "Geçerli dal silinemez.")
        XCTAssertEqual(Actions.blocker(.deleteBranch(name: "yok"), repo: status), "‘yok’ dalı bulunamadı.")
        XCTAssertTrue(try XCTUnwrap(Actions.blocker(.deleteBranch(name: "agacta"), repo: status)).contains("çalışma ağacında açık"))

        for name in ["yarim", "main", "agacta", "yok"] {
            XCTAssertFalse(Actions.perform(.deleteBranch(name: name), repoPath: repo).succeeded, name)
        }
        XCTAssertTrue(branchExists("yarim", in: repo))
        XCTAssertTrue(branchExists("main", in: repo))
        XCTAssertTrue(branchExists("agacta", in: repo))

        let result = Actions.perform(.deleteBranch(name: "bitti"), repoPath: repo)
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertFalse(branchExists("bitti", in: repo))
    }

    func testDefaultBranchIsNeverDeletedEvenWhenNotCurrent() throws {
        let (repo, _) = try makeRepoWithRemote("varsayilan")
        try git("switch", "-q", "-c", "is", in: repo)
        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.defaultBranch, "main")
        XCTAssertEqual(Actions.blocker(.deleteBranch(name: "main"), repo: status), "Varsayılan dal (main) silinemez.")
        XCTAssertEqual(Actions.blocker(.deleteBranch(name: "is"), repo: status), "Geçerli dal silinemez.")
        XCTAssertFalse(Actions.perform(.deleteBranch(name: "main"), repoPath: repo).succeeded)
        XCTAssertTrue(branchExists("main", in: repo))
    }

    func testGitErrorTextIsShownWhenGitRefuses() throws {
        // Dal uzak varsayılan dala birleştirilmiş ama yerel HEAD'e değil: `git branch -d` kendisi reddeder.
        let (repo, _) = try makeRepoWithRemote("gitreddi")
        try git("switch", "-q", "-c", "ozellik", in: repo)
        try commit("özellik", file: "o.txt", in: repo)
        try git("push", "-q", "origin", "ozellik:main", in: repo)
        try git("switch", "-q", "main", in: repo)

        let status = RepoScanner.scan(path: repo)
        XCTAssertEqual(status.branches.first { $0.name == "ozellik" }?.mergedIntoDefault, true)
        let result = Actions.perform(.deleteBranch(name: "ozellik"), repoPath: repo)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("not fully merged"), result.message)
        XCTAssertTrue(branchExists("ozellik", in: repo))
    }

    func testScanErrorBlocksEveryAction() {
        var repo = RepoStatus(path: "/tmp/bozuk")
        repo.scanError = "fatal"
        for action in [RepoAction.fetch, .push, .removeWorktree(path: "/tmp/x"), .deleteBranch(name: "x")] {
            XCTAssertNotNil(Actions.blocker(action, repo: repo))
        }
    }
}
