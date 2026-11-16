import Foundation

/// Kullanıcının düğmeyle başlattığı, depoyu değiştiren işlemler.
public enum RepoAction: Equatable, Sendable {
    case fetch
    case push
    case removeWorktree(path: String)
    case deleteBranch(name: String)

    var mutation: GitMutation {
        switch self {
        case .fetch: return .fetchAll
        case .push: return .push
        case .removeWorktree(let path): return .removeWorktree(path: path)
        case .deleteBranch(let name): return .deleteMergedBranch(name: name)
        }
    }
}

public struct ActionResult: Equatable, Sendable {
    public var succeeded: Bool
    public var message: String
}

public struct ActionConfirmation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmLabel: String
}

public enum Actions {
    /// İşlemin neden yapılamayacağını döndürür; yapılabiliyorsa `nil`. Saf işlev.
    public static func blocker(_ action: RepoAction, repo: RepoStatus) -> String? {
        if let error = repo.scanError { return "Depo taranamadı: \(error)" }
        switch action {
        case .fetch:
            return repo.remotes.isEmpty ? "Uzak depo tanımlı değil." : nil

        case .push:
            guard let branch = repo.status.head.branchName else { return "HEAD bir dala bağlı değil." }
            guard repo.status.upstream != nil else {
                return "‘\(branch)’ dalının upstream'i yok. İlk push'u terminalden yapın: git push -u origin \(branch)"
            }
            guard let ahead = repo.status.ahead, let behind = repo.status.behind else {
                return "Upstream dalı uzak depoda artık yok."
            }
            if ahead == 0 { return "Push'lanacak commit yok." }
            if behind > 0 {
                return "Uzak dal \(behind) commit ileride. Önce terminalden pull ya da rebase yapın; bu uygulama zorla push yapmaz."
            }
            return nil

        case .removeWorktree(let path):
            let target = Paths.canonical(path)
            if target == Paths.canonical(repo.path) { return "Ana çalışma ağacı kaldırılamaz." }
            guard let worktree = repo.worktrees.first(where: { Paths.canonical($0.path) == target }) else {
                return "Bu çalışma ağacı artık kayıtlı değil."
            }
            if worktree.isOrphaned { return "Git bu klasörü tanımıyor; git worktree remove ile kaldırılamaz." }
            if worktree.isPrunable { return "Klasör zaten yok. Kaydı terminalden temizleyin: git worktree prune" }
            if worktree.isLocked { return "Çalışma ağacı kilitli (git worktree lock)." }
            if let error = worktree.scanError { return "Çalışma ağacı taranamadı: \(error)" }
            guard let status = worktree.status else { return "Çalışma ağacının durumu okunamadı." }
            if status.isDirty {
                let sample = status.changedPaths.prefix(3).joined(separator: ", ") + (status.changeCount > 3 ? "…" : "")
                return "\(status.changeCount) dosyada commit'lenmemiş değişiklik var (\(sample)). Önce commit'leyin ya da değişiklikleri kendiniz kaldırın."
            }
            if worktree.danglingCommits > 0 {
                return "HEAD bir dala bağlı değil ve \(worktree.danglingCommits) commit hiçbir dalda yok. Önce bir dal oluşturun."
            }
            return nil

        case .deleteBranch(let name):
            guard let branch = repo.branches.first(where: { $0.name == name }) else { return "‘\(name)’ dalı bulunamadı." }
            if branch.isCurrent { return "Geçerli dal silinemez." }
            guard let def = repo.defaultBranch else { return "Varsayılan dal belirlenemedi; birleştirilmiş olduğu doğrulanamıyor." }
            if name == def { return "Varsayılan dal (\(def)) silinemez." }
            if let path = branch.worktreePath {
                return "Dal bir çalışma ağacında açık: \(Paths.abbreviatingHome(path))"
            }
            if !branch.mergedIntoDefault { return "‘\(name)’ dalı \(def) dalına birleştirilmemiş." }
            return nil
        }
    }

    /// Onay penceresinde gösterilecek metin.
    public static func confirmation(_ action: RepoAction, repo: RepoStatus) -> ActionConfirmation {
        switch action {
        case .fetch:
            return ActionConfirmation(
                title: "Uzak depolardan getirilsin mi?",
                message: "git fetch --all --prune çalıştırılır. Çalışma dosyalarınıza ve dallarınıza dokunulmaz.",
                confirmLabel: "Getir"
            )
        case .push:
            let commits = repo.unpushedCommits
            var lines = commits.prefix(15).map { "• \($0.subject)" }
            if commits.count > 15 { lines.append("… ve \(commits.count - 15) commit daha") }
            lines.append("")
            lines.append("Düz git push çalıştırılır; zorlama (force) yoktur.")
            return ActionConfirmation(
                title: "\(repo.status.ahead ?? commits.count) commit \(repo.status.upstream ?? "upstream") dalına push'lansın mı?",
                message: lines.joined(separator: "\n"),
                confirmLabel: "Push'la"
            )
        case .removeWorktree(let path):
            let worktree = repo.worktrees.first { Paths.canonical($0.path) == Paths.canonical(path) }
            var lines = [Paths.abbreviatingHome(path), ""]
            if let name = worktree?.branch {
                lines.append("‘\(name)’ dalı silinmez; yalnızca klasör kaldırılır.")
                if let branch = repo.branches.first(where: { $0.name == name }), branch.uniqueCommits > 0, !repo.remotes.isEmpty {
                    lines.append("Dikkat: bu dalda \(branch.uniqueCommits) commit henüz hiçbir uzak depoda yok.")
                }
            }
            let ignored = worktree?.status?.ignoredPaths ?? []
            if !ignored.isEmpty {
                let sample = ignored.prefix(8).joined(separator: ", ") + (ignored.count > 8 ? "…" : "")
                lines.append("Git'in yok saydığı \(ignored.count) öğe de klasörle birlikte silinir: \(sample)")
            }
            return ActionConfirmation(
                title: "Çalışma ağacı ‘\(worktree?.name ?? (path as NSString).lastPathComponent)’ kaldırılsın mı?",
                message: lines.joined(separator: "\n"),
                confirmLabel: "Kaldır"
            )
        case .deleteBranch(let name):
            return ActionConfirmation(
                title: "‘\(name)’ dalı silinsin mi?",
                message: "Dal \(repo.defaultBranch ?? "varsayılan") dalına birleştirilmiş. git branch -d çalıştırılır; "
                    + "git birleştirilmemiş commit bulursa silmeyi kendisi reddeder.",
                confirmLabel: "Dalı sil"
            )
        }
    }

    /// Depoyu yeniden tarar, ön koşulu son kez denetler ve ancak geçerse komutu çalıştırır.
    public static func perform(_ action: RepoAction, repoPath: String, config: Config = Config()) -> ActionResult {
        let fresh = RepoScanner.scan(path: repoPath, config: config)
        if let reason = blocker(action, repo: fresh) {
            return ActionResult(succeeded: false, message: "İşlem yapılmadı: \(reason)")
        }
        let output = Git.mutate(action.mutation, in: repoPath)
        guard output.succeeded else {
            return ActionResult(succeeded: false, message: output.errorText)
        }
        let text = (output.stdout + "\n" + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return ActionResult(succeeded: true, message: text)
    }
}
