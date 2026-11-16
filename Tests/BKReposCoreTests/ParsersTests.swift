import XCTest
@testable import BKReposCore

final class ParsersTests: XCTestCase {
    func testStatusBranchHeadersAndCounts() {
        let records = [
            "# branch.oid 6c318dd8cdd77347aedd724bc42a8c20bc9fcea5",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -2",
            "1 M. N... 100644 100644 100644 aaaa bbbb hazir.txt",
            "1 .M N... 100644 100644 100644 aaaa bbbb boşluklu ad.txt",
            "1 MM N... 100644 100644 100644 aaaa bbbb ikisi.txt",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 yeni ad.txt",
            "eski ad.txt",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc çakışma.txt",
            "? izlenmeyen klasör/",
            "? not.md",
            "! node_modules/",
        ]
        let status = Parsers.status(records.joined(separator: "\0") + "\0")
        XCTAssertEqual(status.head, .branch("main"))
        XCTAssertFalse(status.isUnborn)
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 3)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.staged, 3)
        XCTAssertEqual(status.unstaged, 3)
        XCTAssertEqual(status.untracked, 2)
        XCTAssertEqual(status.conflicted, 1)
        XCTAssertEqual(status.changedPaths, [
            "hazir.txt", "boşluklu ad.txt", "ikisi.txt", "yeni ad.txt", "çakışma.txt", "izlenmeyen klasör/", "not.md",
        ])
        XCTAssertEqual(status.ignoredPaths, ["node_modules/"])
        XCTAssertTrue(status.isDirty)
        XCTAssertFalse(status.upstreamGone)
    }

    func testStatusDetachedInitialAndGoneUpstream() {
        let detached = Parsers.status("# branch.oid 1234567890abcdef\0# branch.head (detached)\0")
        XCTAssertEqual(detached.head, .detached("1234567"))
        XCTAssertFalse(detached.isDirty)

        let initial = Parsers.status("# branch.oid (initial)\0# branch.head main\0? a.txt\0")
        XCTAssertTrue(initial.isUnborn)
        XCTAssertEqual(initial.head, .branch("main"))
        XCTAssertEqual(initial.untracked, 1)

        // Upstream ayarlı ama uzak dal silinmiş: `branch.ab` satırı gelmez.
        let gone = Parsers.status("# branch.oid abc\0# branch.head is\0# branch.upstream origin/is\0")
        XCTAssertTrue(gone.upstreamGone)
        XCTAssertNil(gone.ahead)
    }

    func testWorktreeList() {
        let output = """
        worktree /Users/x/proje
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/x/proje/.claude/worktrees/ajan bir
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/ajan/is

        worktree /tmp/ayrik
        HEAD 3333333333333333333333333333333333333333
        detached
        locked sebep

        worktree /tmp/kayip
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/kayip
        prunable gitdir file points to non-existent location

        """
        let list = Parsers.worktrees(output)
        XCTAssertEqual(list.map(\.path), ["/Users/x/proje", "/Users/x/proje/.claude/worktrees/ajan bir", "/tmp/ayrik", "/tmp/kayip"])
        XCTAssertEqual(list.map(\.isMain), [true, false, false, false])
        XCTAssertEqual(list[1].branch, "ajan/is")
        XCTAssertEqual(list[1].name, "ajan bir")
        XCTAssertTrue(list[2].isDetached)
        XCTAssertTrue(list[2].isLocked)
        XCTAssertNil(list[2].branch)
        XCTAssertTrue(list[3].isPrunable)
    }

    func testTrackAndBranches() {
        XCTAssertTrue(Parsers.track("[gone]").gone)
        XCTAssertEqual(Parsers.track("[ahead 2, behind 5]").ahead, 2)
        XCTAssertEqual(Parsers.track("[ahead 2, behind 5]").behind, 5)
        XCTAssertEqual(Parsers.track("[behind 7]").behind, 7)
        XCTAssertEqual(Parsers.track("").ahead, 0)

        let output = [
            "refs/heads/main\0origin/main\0[ahead 1]\u{0}1700000000\0*\0/Users/x/proje",
            "refs/heads/feat/x\0\0\u{0}1700000100\0 \0",
            "refs/heads/eski\0origin/eski\0[gone]\u{0}1600000000\0 \0/tmp/wt",
        ].joined(separator: "\n") + "\n"
        let branches = Parsers.branches(output)
        XCTAssertEqual(branches.map(\.name), ["main", "feat/x", "eski"])
        XCTAssertTrue(branches[0].isCurrent)
        XCTAssertEqual(branches[0].ahead, 1)
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertNil(branches[1].upstream)
        XCTAssertNil(branches[1].worktreePath)
        XCTAssertTrue(branches[2].upstreamGone)
        XCTAssertEqual(branches[2].worktreePath, "/tmp/wt")
        XCTAssertEqual(branches[1].lastCommit, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testRemotesCommitsAndPointer() {
        let remotes = Parsers.remotes("origin\tgit@github.com:a/b.git (fetch)\norigin\tgit@github.com:a/b.git (push)\nyedek\t/tmp/y.git (fetch)\n")
        XCTAssertEqual(remotes, [Remote(name: "origin", url: "git@github.com:a/b.git"), Remote(name: "yedek", url: "/tmp/y.git")])

        let commits = Parsers.commits("1700000000\0ilk: iki nokta\n1700000500\0\n")
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "ilk: iki nokta")
        XCTAssertEqual(commits[1].subject, "")

        XCTAssertEqual(Parsers.gitdirPointer("gitdir: /a/b/.git/worktrees/x\n"), "/a/b/.git/worktrees/x")
        XCTAssertNil(Parsers.gitdirPointer("başka bir şey"))
    }

    // MARK: Git komut sınırları

    func testOnlyReadOnlyCommandsPassTheReadGate() {
        for allowed in [
            ["status", "--porcelain=v2"], ["log", "-1"], ["rev-parse", "HEAD"], ["for-each-ref", "refs/heads"],
            ["branch", "--list"], ["stash", "list"], ["worktree", "list", "--porcelain"], ["remote", "-v"],
            ["config", "--get", "init.defaultBranch"], ["rev-list", "--count", "HEAD"],
        ] {
            XCTAssertTrue(Git.isReadOnly(allowed), "\(allowed)")
        }
        for refused in [
            ["push"], ["push", "--force"], ["fetch"], ["pull"], ["reset", "--hard"], ["checkout", "."], ["clean", "-fd"],
            ["stash", "drop"], ["stash"], ["rebase"], ["branch", "-D", "x"], ["branch", "-d", "x"], ["worktree", "remove", "x"],
            ["worktree", "prune"], ["remote", "remove", "origin"], ["config", "user.name", "x"], ["commit"], ["switch", "x"], [],
        ] {
            XCTAssertFalse(Git.isReadOnly(refused), "\(refused)")
        }
        // Reddedilen komut çalıştırılmaz.
        let output = Git.read(["reset", "--hard"], in: NSTemporaryDirectory())
        XCTAssertFalse(output.succeeded)
        XCTAssertTrue(output.stderr.contains("reddedildi"))
    }

    func testMutationsAreExactlyTheFourAllowedCommands() {
        XCTAssertEqual(GitMutation.fetchAll.arguments, ["fetch", "--all", "--prune"])
        XCTAssertEqual(GitMutation.push.arguments, ["push"])
        XCTAssertEqual(GitMutation.removeWorktree(path: "/tmp/wt").arguments, ["worktree", "remove", "/tmp/wt"])
        XCTAssertEqual(GitMutation.deleteMergedBranch(name: "eski").arguments, ["branch", "-d", "--", "eski"])
        let all: [GitMutation] = [.fetchAll, .push, .removeWorktree(path: "/x"), .deleteMergedBranch(name: "x")]
        for mutation in all {
            for forbidden in ["--force", "-f", "-D", "--force-with-lease", "--mirror", "--delete"] {
                XCTAssertFalse(mutation.arguments.contains(forbidden), "\(mutation) içinde \(forbidden)")
            }
        }
    }

    // MARK: Ayarlar ve biçimler

    func testConfigDefaultsAndPartialFile() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"roots": ["~/kod"], "reminderTime": "09:30"}"#.utf8))
        XCTAssertEqual(config.roots, ["~/kod"])
        XCTAssertEqual(config.unpushedCriticalDays, 1)
        XCTAssertEqual(config.uncommittedCriticalDays, 3)
        XCTAssertEqual(config.maxDepth, 3)
        XCTAssertEqual(config.reminderHourMinute.hour, 9)
        XCTAssertEqual(config.reminderHourMinute.minute, 30)
        XCTAssertEqual(Config().roots, ["~/Documents/GitHub", "~/IdeaProjects"])
        XCTAssertEqual(Config().reminderHourMinute.hour, 18)
        var broken = Config()
        broken.reminderTime = "akşam"
        XCTAssertEqual(broken.reminderHourMinute.hour, 18)
    }

    func testTurkishDurations() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        XCTAssertEqual(Format.since(ago(20), now: now), "az önce")
        XCTAssertEqual(Format.since(ago(5 * 60), now: now), "5 dakikadır")
        XCTAssertEqual(Format.since(ago(3 * 3600), now: now), "3 saattir")
        XCTAssertEqual(Format.since(ago(2 * 86_400 + 60), now: now), "2 gündür")
        XCTAssertEqual(Format.since(ago(90 * 86_400), now: now), "3 aydır")
        XCTAssertEqual(Format.since(ago(800 * 86_400), now: now), "2 yıldır")
        XCTAssertEqual(Format.ago(ago(86_400 + 60), now: now), "dün")
        XCTAssertEqual(Format.ago(ago(4 * 86_400), now: now), "4 gün önce")
    }
}
