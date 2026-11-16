import Foundation

/// Git çıktılarını ayrıştıran saf işlevler. Dosya sistemine ya da git'e dokunmazlar.
public enum Parsers {
    /// `git status --porcelain=v2 --branch -z` çıktısı. Kayıtlar NUL ile ayrılır.
    public static func status(_ output: String) -> WorkingTreeStatus {
        var result = WorkingTreeStatus()
        var seen = Set<String>()
        var oid = ""
        var headName = ""
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        func addChanged(_ path: String) {
            if seen.insert(path).inserted { result.changedPaths.append(path) }
        }
        /// `count` alanı atlayıp kalanını (boşluk içerebilen yolu) döndürür.
        func path(of record: String, afterFields count: Int) -> String? {
            let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            return parts.count == count + 1 ? String(parts[count]) : nil
        }

        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid":
                    oid = parts[1]
                    if oid == "(initial)" { result.isUnborn = true }
                case "branch.head": headName = parts[1]
                case "branch.upstream": result.upstream = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2, let a = Int(ab[0].dropFirst()), let b = Int(ab[1].dropFirst()) {
                        result.ahead = a
                        result.behind = b
                    }
                default: break
                }
                continue
            }
            guard let kind = record.first else { continue }
            switch kind {
            case "1", "2", "u":
                let xy = Array(record.dropFirst(2).prefix(2))
                guard xy.count == 2 else { continue }
                // Yoldan önceki alan sayısı: 1 → 8, 2 → 9 (ardından eski yol ayrı kayıt), u → 10.
                let fields = kind == "1" ? 8 : kind == "2" ? 9 : 10
                guard let p = path(of: record, afterFields: fields) else { continue }
                if kind == "2" { index += 1 }
                if kind == "u" {
                    result.conflicted += 1
                    result.unstaged += 1
                } else {
                    if xy[0] != "." { result.staged += 1 }
                    if xy[1] != "." { result.unstaged += 1 }
                }
                addChanged(p)
            case "?":
                result.untracked += 1
                addChanged(String(record.dropFirst(2)))
            case "!":
                result.ignoredPaths.append(String(record.dropFirst(2)))
            default: break
            }
        }
        result.head = headName == "(detached)" || headName.isEmpty
            ? .detached(String(oid.prefix(7)))
            : .branch(headName)
        return result
    }

    /// `git worktree list --porcelain` çıktısı. İlk kayıt ana çalışma ağacıdır.
    public static func worktrees(_ output: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var current: WorktreeInfo?
        func flush() {
            if var wt = current {
                wt.isMain = result.isEmpty
                result.append(wt)
            }
            current = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "worktree":
                flush()
                current = WorktreeInfo(path: value)
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true
            case "prunable": current?.isPrunable = true
            default: break
            }
        }
        flush()
        return result
    }

    /// `for-each-ref` için dal biçimi; alanlar NUL ile ayrılır.
    static let branchFormat =
        "%(refname)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(HEAD)%00%(worktreepath)"

    public static func branches(_ output: String) -> [BranchInfo] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, f[0].hasPrefix("refs/heads/") else { return nil }
            var branch = BranchInfo(name: String(f[0].dropFirst("refs/heads/".count)))
            branch.upstream = f[1].isEmpty ? nil : f[1]
            let track = Parsers.track(f[2])
            branch.upstreamGone = track.gone
            branch.ahead = track.ahead
            branch.behind = track.behind
            branch.lastCommit = TimeInterval(f[3]).map(Date.init(timeIntervalSince1970:))
            branch.isCurrent = f[4] == "*"
            branch.worktreePath = f[5].isEmpty ? nil : f[5]
            return branch
        }
    }

    /// `%(upstream:track)`: "[ahead 2, behind 1]", "[ahead 2]", "[behind 1]", "[gone]" ya da boş.
    public static func track(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if inner == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in inner.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }

    /// `git remote -v` çıktısı; her uzak depo bir kez (fetch adresiyle).
    public static func remotes(_ output: String) -> [Remote] {
        var result: [Remote] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !result.contains(where: { $0.name == parts[0] }) else { continue }
            var url = parts[1]
            for suffix in [" (fetch)", " (push)"] where url.hasSuffix(suffix) { url.removeLast(suffix.count) }
            result.append(Remote(name: parts[0], url: url))
        }
        return result
    }

    /// `--format=%ct%x00%s` satırları.
    public static func commits(_ output: String) -> [CommitInfo] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let seconds = TimeInterval(f[0]) else { return nil }
            return CommitInfo(date: Date(timeIntervalSince1970: seconds), subject: f.count > 1 ? f[1] : "")
        }
    }

    /// Bağlı çalışma ağaçlarındaki `.git` dosyasının içeriği: `gitdir: <yol>`.
    public static func gitdirPointer(_ contents: String) -> String? {
        for line in contents.split(separator: "\n") where line.hasPrefix("gitdir:") {
            let value = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
