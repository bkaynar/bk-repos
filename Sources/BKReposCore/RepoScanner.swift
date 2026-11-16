import Foundation

/// Bir deponun durumunu yalnızca salt okunur git komutlarıyla toplar. Ağa çıkmaz (fetch yok).
public enum RepoScanner {
    static let commitFormat = "--format=%ct%x00%s"
    /// Tarihine bakılacak en fazla dosya ve listelenecek en fazla commit.
    static let fileLimit = 2000
    static let commitLimit = 500

    public static func scan(path: String, config: Config = Config(), extraOrphans: [String] = []) -> RepoStatus {
        var repo = RepoStatus(path: path)

        let statusOutput = readStatus(in: path, includeIgnored: false)
        guard statusOutput.succeeded else {
            repo.scanError = statusOutput.errorText
            return repo
        }
        repo.status = Parsers.status(statusOutput.stdout)
        (repo.oldestChange, repo.newestChange) = changeDates(repo.status.changedPaths, in: path)

        repo.remotes = Parsers.remotes(Git.read(["remote", "-v"], in: path).stdout)

        let stashes = Git.read(["stash", "list", "--format=%ct"], in: path).stdout
            .split(separator: "\n").compactMap { TimeInterval($0) }
        repo.stashCount = stashes.count
        repo.oldestStash = stashes.min().map(Date.init(timeIntervalSince1970:))

        if repo.hasCommits {
            repo.lastCommit = Parsers.commits(Git.read(["log", "-1", commitFormat], in: path).stdout).first
            readBranches(into: &repo)
            if repo.status.upstream != nil, (repo.status.ahead ?? 0) > 0 {
                let log = Git.read(["log", commitFormat, "-n", "\(commitLimit)", "@{upstream}..HEAD"], in: path)
                repo.unpushedCommits = Parsers.commits(log.stdout)
            }
            if repo.status.head.branchName == nil {
                repo.danglingCommits = danglingCommits(in: path)
            }
        }

        readWorktrees(into: &repo, config: config, extraOrphans: extraOrphans)
        return repo
    }

    // MARK: Durum ve dosya tarihleri

    static func readStatus(in path: String, includeIgnored: Bool) -> ShellOutput {
        // `--untracked-files=normal`: kullanıcının git ayarı ne olursa olsun izlenmeyen dosyalar sayılır.
        var arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]
        if includeIgnored { arguments.append("--ignored") }
        return Git.read(arguments, in: path, timeout: 60)
    }

    /// Değişen dosyaların en eski ve en yeni değiştirilme tarihleri. Silinmiş dosyaların tarihi yoktur.
    static func changeDates(_ paths: [String], in root: String) -> (oldest: Date?, newest: Date?) {
        var oldest: Date?
        var newest: Date?
        for relative in paths.prefix(fileLimit) {
            guard let date = modificationDate(root + "/" + relative) else { continue }
            if oldest == nil || date < oldest! { oldest = date }
            if newest == nil || date > newest! { newest = date }
        }
        return (oldest, newest)
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Dallar

    static func readBranches(into repo: inout RepoStatus) {
        let path = repo.path
        let refs = Git.read(["for-each-ref", "--format=" + Parsers.branchFormat, "refs/heads"], in: path)
        var branches = Parsers.branches(refs.stdout)
        guard !branches.isEmpty else { return }

        // Uzak dal adları: refs/remotes/<uzak>/<dal>.
        let remoteRefs = Set(
            Git.read(["for-each-ref", "--format=%(refname)", "refs/remotes"], in: path).stdout
                .split(separator: "\n").map(String.init)
        )
        let remoteNames = repo.remotes.map(\.name)
        func remoteHas(_ branch: String) -> Bool {
            remoteNames.contains { remoteRefs.contains("refs/remotes/\($0)/\(branch)") }
        }

        repo.defaultBranch = defaultBranch(in: path, remotes: remoteNames, locals: branches.map(\.name))

        // Varsayılan dala (yerel ya da uzak hâline) birleştirilmiş dallar.
        var merged = Set<String>()
        if let def = repo.defaultBranch {
            var targets = branches.contains(where: { $0.name == def }) ? ["refs/heads/\(def)"] : []
            targets += remoteNames.map { "refs/remotes/\($0)/\(def)" }.filter(remoteRefs.contains)
            for target in targets {
                let out = Git.read(["for-each-ref", "--format=%(refname)", "--merged=" + target, "refs/heads"], in: path)
                for line in out.stdout.split(separator: "\n") where line.hasPrefix("refs/heads/") {
                    merged.insert(String(line.dropFirst("refs/heads/".count)))
                }
            }
            merged.remove(def)
        }

        // Hiçbir uzak depoda olmayan commit'ler. Uzak depo yoksa depo zaten bütünüyle işaretlenir.
        var anyUnique = false
        if !remoteNames.isEmpty {
            let count = Git.read(["rev-list", "--count", "--branches", "--not", "--remotes"], in: path).stdout
            anyUnique = (Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) > 0
        }

        for index in branches.indices {
            let name = branches[index].name
            branches[index].mergedIntoDefault = merged.contains(name)
            branches[index].existsOnRemote =
                (branches[index].upstream != nil && !branches[index].upstreamGone) || remoteHas(name)
            if anyUnique {
                let log = Git.read(
                    ["log", commitFormat, "-n", "\(commitLimit)", "refs/heads/" + name, "--not", "--remotes"], in: path
                )
                let commits = Parsers.commits(log.stdout)
                branches[index].uniqueCommits = commits.count
                branches[index].oldestUnique = commits.map(\.date).min()
            }
        }
        repo.branches = branches
    }

    /// Varsayılan dal: uzak deponun HEAD'i, yoksa bilinen adlardan yerelde bulunan ilk dal.
    static func defaultBranch(in path: String, remotes: [String], locals: [String]) -> String? {
        let ordered = remotes.sorted { a, b in a == "origin" && b != "origin" }
        for remote in ordered {
            let out = Git.read(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], in: path)
            let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.succeeded, value.hasPrefix(remote + "/") {
                return String(value.dropFirst(remote.count + 1))
            }
        }
        for candidate in ["main", "master", "develop", "trunk"] where locals.contains(candidate) {
            return candidate
        }
        let configured = Git.read(["config", "--get", "init.defaultBranch"], in: path).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return locals.contains(configured) ? configured : nil
    }

    /// Ayrık HEAD'de, hiçbir dalda ve uzak depoda bulunmayan commit sayısı.
    static func danglingCommits(in path: String) -> Int {
        let out = Git.read(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], in: path)
        return Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Çalışma ağaçları

    static func readWorktrees(into repo: inout RepoStatus, config: Config, extraOrphans: [String]) {
        let listed = Parsers.worktrees(Git.read(["worktree", "list", "--porcelain"], in: repo.path).stdout)
        let mainPath = Paths.canonical(repo.path)
        var known: Set<String> = [mainPath]

        for var worktree in listed where !worktree.isMain && !worktree.isBare {
            let canonical = Paths.canonical(worktree.path)
            guard canonical != mainPath else { continue }
            known.insert(canonical)
            if !worktree.isPrunable {
                if FileManager.default.fileExists(atPath: worktree.path) {
                    inspect(&worktree)
                } else {
                    worktree.isPrunable = true
                }
            }
            repo.worktrees.append(worktree)
        }

        // Git'in tanımadığı kopuk çalışma ağacı klasörleri.
        var candidates = extraOrphans
        for relative in config.worktreeDirectories {
            let parent = repo.path + "/" + relative
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            candidates += names.sorted().map { parent + "/" + $0 }
        }
        for candidate in candidates {
            let canonical = Paths.canonical(candidate)
            guard !known.contains(canonical), case .orphan(let pointer) = GitEntry.classify(candidate) else { continue }
            known.insert(canonical)
            var worktree = WorktreeInfo(path: candidate)
            worktree.isOrphaned = true
            worktree.orphanPointer = pointer
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: candidate)) ?? []
            worktree.lastActivity = ([candidate] + entries.map { candidate + "/" + $0 }).compactMap(modificationDate).max()
            repo.worktrees.append(worktree)
        }
    }

    /// Bağlı bir çalışma ağacının kendi durumunu okur.
    static func inspect(_ worktree: inout WorktreeInfo) {
        let path = worktree.path
        // Yok sayılan dosyalar da okunur: çalışma ağacı kaldırılırsa onlar da silinir, onayda gösterilir.
        let output = readStatus(in: path, includeIgnored: true)
        guard output.succeeded else {
            worktree.scanError = output.errorText
            return
        }
        let status = Parsers.status(output.stdout)
        worktree.status = status
        let dates = changeDates(status.changedPaths, in: path)
        worktree.oldestChange = dates.oldest

        var activity: [Date] = []
        if let newest = dates.newest { activity.append(newest) }
        if !status.isUnborn,
           let commit = Parsers.commits(Git.read(["log", "-1", commitFormat], in: path).stdout).first {
            activity.append(commit.date)
        }
        // Çalışma ağacının oluşturulması, dal değiştirme ve commit'ler git klasöründeki bu dosyalara yansır.
        activity += [path + "/.git"].compactMap(modificationDate)
        if let contents = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
           let pointer = Parsers.gitdirPointer(contents) {
            let gitdir = pointer.hasPrefix("/") ? pointer : path + "/" + pointer
            activity += ["index", "HEAD", "logs/HEAD"].compactMap { modificationDate(gitdir + "/" + $0) }
        }
        worktree.lastActivity = activity.max()

        if status.head.branchName == nil, !status.isUnborn {
            worktree.isDetached = true
            worktree.danglingCommits = danglingCommits(in: path)
        }
    }

    // MARK: Toplu tarama

    /// Tüm depoları bulur ve sınırlı paralellikle tarar. Sonuç riske göre sıralıdır.
    /// `progress` herhangi bir iş parçacığından çağrılabilir: (biten, toplam, depo adı).
    public static func scanAll(
        config: Config, now: Date = Date(),
        progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }
    ) -> [RepoReport] {
        let found = Discovery.find(config: config)
        let repoKeys = found.repos.map { Paths.canonical($0) }

        // Kopuk klasörler, içinde bulundukları en yakın depoya bağlanır.
        var orphansByRepo: [Int: [String]] = [:]
        for orphan in found.orphans {
            let key = Paths.canonical(orphan)
            let owner = repoKeys.indices
                .filter { key.hasPrefix(repoKeys[$0] + "/") }
                .max { repoKeys[$0].count < repoKeys[$1].count }
            if let owner { orphansByRepo[owner, default: []].append(orphan) }
        }

        let total = found.repos.count
        let lock = NSLock()
        var reports = [RepoReport?](repeating: nil, count: total)
        var done = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, config.parallelism)
        queue.qualityOfService = .utility
        for (index, path) in found.repos.enumerated() {
            queue.addOperation {
                let repo = scan(path: path, config: config, extraOrphans: orphansByRepo[index] ?? [])
                let report = RepoReport(repo: repo, findings: Risk.evaluate(repo, config: config, now: now))
                lock.lock()
                reports[index] = report
                done += 1
                let finished = done
                lock.unlock()
                progress(finished, total, repo.name)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return sorted(reports.compactMap { $0 })
    }

    /// Önce en riskli; aynı düzeyde ada göre.
    public static func sorted(_ reports: [RepoReport]) -> [RepoReport] {
        reports.sorted { a, b in
            if a.level != b.level { return a.level > b.level }
            return a.repo.name.localizedStandardCompare(b.repo.name) == .orderedAscending
        }
    }
}
