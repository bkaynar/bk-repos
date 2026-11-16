import Foundation

/// Tarama sonucunu "kaybolabilecek iş" açısından değerlendirir. Saf işlev: git'e dokunmaz.
public enum Risk {
    public static func evaluate(_ repo: RepoStatus, config: Config = Config(), now: Date = Date()) -> [Finding] {
        var findings: [Finding] = []

        if let error = repo.scanError {
            return [Finding(.warning, "Depo taranamadı", detail: error)]
        }

        // Uzak depo
        if repo.remotes.isEmpty {
            if repo.hasCommits {
                findings.append(Finding(
                    .critical, "Uzak depo yok: bu projenin tek kopyası bu bilgisayarda",
                    detail: "Disk bozulursa ya da klasör silinirse commit'ler geri getirilemez. Bir uzak depo ekleyip push'layın."
                ))
            } else {
                findings.append(Finding(.clean, "Henüz commit yok, uzak depo da tanımlı değil"))
            }
        }

        // Commit'lenmemiş değişiklikler
        if repo.status.isDirty {
            findings.append(uncommitted(repo.status, oldest: repo.oldestChange, prefix: "", config: config, now: now))
        }

        // Ayrık HEAD
        if case .detached(let oid) = repo.status.head, repo.hasCommits {
            if repo.danglingCommits > 0 {
                findings.append(Finding(
                    .critical, "HEAD bir dala bağlı değil (\(oid)): \(repo.danglingCommits) commit hiçbir dalda yok",
                    detail: "Başka bir dala geçerseniz bu commit'lere ulaşmak zorlaşır. Bir dal oluşturun: git switch -c <dal-adı>"
                ))
            } else {
                findings.append(Finding(.clean, "HEAD bir dala bağlı değil (\(oid))"))
            }
        }

        // Dallar: yalnızca uzak depo varken anlamlı; yoksa deponun tamamı zaten işaretlendi.
        if !repo.remotes.isEmpty {
            for branch in repo.branches {
                findings += branchFindings(branch, repo: repo, config: config, now: now)
            }
        }

        // Stash
        if repo.stashCount > 0 {
            var text = "\(repo.stashCount) stash var"
            if let oldest = repo.oldestStash { text += " (en eskisi \(Format.ago(oldest, now: now)))" }
            findings.append(Finding(.warning, text, detail: "Stash'ler hiçbir zaman push'lanmaz; yalnızca bu bilgisayarda durur."))
        }

        // Birleştirilmiş, silinebilir dallar
        let deletable = deletableBranches(repo)
        if !deletable.isEmpty, let def = repo.defaultBranch {
            let names = deletable.prefix(6).map(\.name).joined(separator: ", ") + (deletable.count > 6 ? "…" : "")
            findings.append(Finding(
                .warning,
                deletable.count == 1
                    ? "1 dal \(def) dalına birleştirilmiş, silinebilir: \(names)"
                    : "\(deletable.count) dal \(def) dalına birleştirilmiş, silinebilir: \(names)"
            ))
        }

        // Çalışma ağaçları
        for worktree in repo.worktrees {
            findings.append(worktreeFinding(worktree, repo: repo, config: config, now: now))
        }

        // Kararlı sıralama: önce en riskli.
        return findings.enumerated()
            .sorted { $0.element.level != $1.element.level ? $0.element.level > $1.element.level : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Silme düğmesi sunulan dallar: varsayılan dala birleştirilmiş, geçerli olmayan, hiçbir çalışma ağacında açık olmayan.
    public static func deletableBranches(_ repo: RepoStatus) -> [BranchInfo] {
        repo.branches.filter {
            $0.mergedIntoDefault && !$0.isCurrent && $0.name != repo.defaultBranch && $0.worktreePath == nil
        }
    }

    static func uncommitted(
        _ status: WorkingTreeStatus, oldest: Date?, prefix: String, config: Config, now: Date
    ) -> Finding {
        var parts: [String] = []
        if status.staged > 0 { parts.append("\(status.staged) hazırlanmış (staged)") }
        if status.unstaged > 0 { parts.append("\(status.unstaged) değişmiş") }
        if status.untracked > 0 { parts.append("\(status.untracked) izlenmeyen") }
        if status.conflicted > 0 { parts.append("\(status.conflicted) çakışmalı") }
        var text = "\(prefix)\(status.changeCount) dosyada commit'lenmemiş değişiklik"
        var level = RiskLevel.warning
        if let oldest {
            text += " (en eskisi \(Format.since(oldest, now: now)))"
            if Format.days(oldest, now: now) >= config.uncommittedCriticalDays { level = .critical }
        }
        return Finding(level, text, detail: parts.joined(separator: ", "))
    }

    static func branchFindings(_ branch: BranchInfo, repo: RepoStatus, config: Config, now: Date) -> [Finding] {
        var findings: [Finding] = []
        let quoted = "‘\(branch.name)’"
        // Varsayılan dala birleştirilmiş bir dalın commit'leri varsayılan dalda da vardır; orada raporlanır.
        let coveredByDefault = branch.mergedIntoDefault && branch.name != repo.defaultBranch

        if branch.uniqueCommits > 0, !coveredByDefault {
            let count = branch.uniqueCommits >= RepoScanner.commitLimit ? "\(RepoScanner.commitLimit)+" : "\(branch.uniqueCommits)"
            let age = branch.oldestUnique.map { " (\(Format.since($0, now: now)))" } ?? ""
            if !branch.existsOnRemote {
                findings.append(Finding(
                    .critical, "\(quoted) dalı hiçbir uzak depoda yok: \(count) commit yalnızca bu bilgisayarda\(age)",
                    detail: branch.upstreamGone
                        ? "Dalın bağlı olduğu uzak dal silinmiş. Commit'ler hâlâ gerekiyorsa yeniden push'layın."
                        : "İlk push için: git push -u origin \(branch.name)"
                ))
            } else {
                let old = branch.oldestUnique.map { Format.days($0, now: now) >= config.unpushedCriticalDays } ?? false
                let text = branch.isCurrent
                    ? "\(count) commit push'lanmamış\(age)"
                    : "\(quoted) dalında \(count) commit push'lanmamış\(age)"
                findings.append(Finding(old ? .critical : .warning, text))
            }
        } else if branch.ahead > 0, !branch.upstreamGone, !coveredByDefault {
            findings.append(Finding(
                .warning, "\(quoted) dalı upstream'inin \(branch.ahead) commit önünde",
                detail: "Bu commit'ler başka bir uzak dalda mevcut; kaybolma riski yok ama dal push'lanmamış."
            ))
        }

        if branch.isCurrent, branch.behind > 0 {
            findings.append(Finding(
                .clean, "Uzak daldan \(branch.behind) commit geride",
                detail: "Son getirilen (fetch) bilgiye göre. Güncel durum için Getir düğmesini kullanın."
            ))
        }
        return findings
    }

    static func worktreeFinding(_ worktree: WorktreeInfo, repo: RepoStatus, config: Config, now: Date) -> Finding {
        let label = "Çalışma ağacı ‘\(worktree.name)’"
        if worktree.isOrphaned {
            return Finding(
                .warning, "Kopuk çalışma ağacı ‘\(worktree.name)’: git bu klasörü tanımıyor",
                detail: ".git dosyası \(worktree.orphanPointer ?? "?") konumunu gösteriyor ama orası yok. "
                    + "İçindeki dosyalar hiçbir depoya bağlı değil; içinde kaydedilmemiş iş olup olmadığını git söyleyemez."
            )
        }
        if worktree.isPrunable {
            return Finding(.warning, "\(label) git'e kayıtlı ama klasörü yok",
                           detail: "Terminalden temizleyebilirsiniz: git worktree prune")
        }
        if let error = worktree.scanError {
            return Finding(.warning, "\(label) taranamadı", detail: error)
        }
        if worktree.danglingCommits > 0 {
            return Finding(
                .critical, "\(label): HEAD bir dala bağlı değil, \(worktree.danglingCommits) commit hiçbir dalda yok",
                detail: "Çalışma ağacı kaldırılırsa bu commit'lere ulaşmak zorlaşır. İçinde bir dal oluşturun."
            )
        }
        if let status = worktree.status, status.isDirty {
            return uncommitted(status, oldest: worktree.oldestChange, prefix: "\(label): ", config: config, now: now)
        }
        let branchNote = worktree.branch.map { name -> String in
            guard let branch = repo.branches.first(where: { $0.name == name }) else { return "dal: \(name)" }
            var notes = ["dal: \(name)"]
            if branch.mergedIntoDefault { notes.append("birleştirilmiş") }
            if !repo.remotes.isEmpty { notes.append(branch.uniqueCommits == 0 ? "push'lanmış" : "push'lanmamış commit var") }
            return notes.joined(separator: ", ")
        } ?? "ayrık HEAD"
        if let activity = worktree.lastActivity, Format.days(activity, now: now) >= config.staleWorktreeDays {
            return Finding(
                .warning, "\(label) temiz ve \(Format.since(activity, now: now)) dokunulmamış; kaldırılabilir",
                detail: branchNote
            )
        }
        return Finding(.clean, "\(label) temiz", detail: branchNote)
    }
}
