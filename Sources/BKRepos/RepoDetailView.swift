import SwiftUI
import BKReposCore

struct RepoDetailView: View {
    let state: AppState
    let report: RepoReport

    private var repo: RepoStatus { report.repo }
    private var isBusy: Bool { state.busyRepo != nil || state.isScanning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                findings
                if !repo.worktrees.isEmpty { worktrees }
                let deletable = Risk.deletableBranches(repo)
                if !deletable.isEmpty { mergedBranches(deletable) }
                if repo.branches.count > 1 { branches }
                if !repo.remotes.isEmpty { remotes }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Başlık

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(repo.name).font(.title2.bold())
                RiskBadge(level: report.level)
            }
            Text(Paths.abbreviatingHome(repo.path))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if repo.scanError == nil {
                Label(branchLine, systemImage: "arrow.triangle.branch")
                    .font(.callout)
                if let commit = repo.lastCommit {
                    Label("Son commit \(Format.ago(commit.date)): \(commit.subject)", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var branchLine: String {
        var text = repo.headDescription
        if let upstream = repo.status.upstream {
            text += " → \(upstream)"
            if let ahead = repo.status.ahead, let behind = repo.status.behind {
                if ahead > 0 || behind > 0 { text += "  (\(ahead) ileride, \(behind) geride)" }
            } else {
                text += "  (uzak dal artık yok)"
            }
        } else if repo.status.head.branchName != nil, !repo.remotes.isEmpty {
            text += "  (upstream yok)"
        }
        return text
    }

    // MARK: İşlemler

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Editors.openInFinder(repo.path)
                } label: {
                    Label("Finder'da aç", systemImage: "folder")
                }
                Button {
                    Editors.openInTerminal(repo.path)
                } label: {
                    Label("Terminal'de aç", systemImage: "terminal")
                }
                editorButton

                Spacer(minLength: 12)

                Button {
                    state.request(.fetch, in: report)
                } label: {
                    Label("Getir", systemImage: "arrow.down.circle")
                }
                .disabled(isBusy || Actions.blocker(.fetch, repo: repo) != nil)
                .help(Actions.blocker(.fetch, repo: repo) ?? "git fetch --all --prune: uzak depoların güncel durumunu getirir, dosyalarınıza dokunmaz")

                Button {
                    state.request(.push, in: report)
                } label: {
                    Label("Push'la", systemImage: "arrow.up.circle")
                }
                .disabled(isBusy || Actions.blocker(.push, repo: repo) != nil)
                .help(Actions.blocker(.push, repo: repo) ?? "Onaydan sonra düz git push çalıştırır")
            }

            if state.busyRepo == repo.path {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.busyText).foregroundStyle(.secondary)
                }
                .font(.callout)
            } else if let message = state.lastActionMessage[repo.path] {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var editorButton: some View {
        let editors = state.editors
        if editors.count == 1, let editor = editors.first {
            Button {
                Editors.open(repo.path, with: editor)
            } label: {
                Label("\(editor.name) ile aç", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } else if editors.count > 1 {
            Menu {
                ForEach(editors) { editor in
                    Button(editor.name) { Editors.open(repo.path, with: editor) }
                }
            } label: {
                Label("Editörde aç", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .fixedSize()
        }
    }

    // MARK: Bulgular

    private var findings: some View {
        Card(title: "Bulgular") {
            if report.findings.isEmpty {
                Label("Kaybolabilecek bir iş yok: her şey commit'lenmiş ve push'lanmış.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.findings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }

    // MARK: Çalışma ağaçları

    private var worktrees: some View {
        Card(title: "Çalışma ağaçları (\(repo.worktrees.count))") {
            ForEach(repo.worktrees) { worktree in
                let blocker = Actions.blocker(.removeWorktree(path: worktree.path), repo: repo)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.on.square.dashed")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worktree.name).fontWeight(.medium)
                        Text(Paths.abbreviatingHome(worktree.path))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(worktreeSummary(worktree))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let blocker {
                            Label("Kaldırılamaz: \(blocker)", systemImage: "lock")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        Editors.openInFinder(worktree.path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Finder'da aç")
                    .disabled(worktree.isPrunable)
                    Button("Kaldır…") {
                        state.request(.removeWorktree(path: worktree.path), in: report)
                    }
                    .disabled(isBusy || blocker != nil)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func worktreeSummary(_ worktree: WorktreeInfo) -> String {
        var parts: [String] = []
        if worktree.isOrphaned {
            parts.append("git bağlantısı kopuk")
        } else if worktree.isPrunable {
            parts.append("klasörü yok")
        } else {
            if let name = worktree.branch {
                var text = "dal: \(name)"
                if let branch = repo.branches.first(where: { $0.name == name }) {
                    if branch.mergedIntoDefault { text += " (birleştirilmiş)" }
                    if !repo.remotes.isEmpty {
                        text += branch.uniqueCommits == 0 ? " (push'lanmış)" : " (\(branch.uniqueCommits) commit push'lanmamış)"
                    }
                }
                parts.append(text)
            } else {
                parts.append("ayrık HEAD")
            }
            if let status = worktree.status {
                parts.append(status.isDirty ? "\(status.changeCount) dosyada değişiklik" : "temiz")
            }
            if worktree.isLocked { parts.append("kilitli") }
        }
        if let activity = worktree.lastActivity { parts.append("son etkinlik \(Format.ago(activity))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Dallar

    private func mergedBranches(_ branches: [BranchInfo]) -> some View {
        Card(title: "Birleştirilmiş dallar (\(branches.count))") {
            Text("Bu dallar \(repo.defaultBranch ?? "varsayılan") dalına birleştirilmiş; silmek commit kaybettirmez.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(branches) { branch in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(branch.name)
                    if let date = branch.lastCommit {
                        Text("son commit \(Format.ago(date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Sil…") {
                        state.request(.deleteBranch(name: branch.name), in: report)
                    }
                    .disabled(isBusy)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var branches: some View {
        Card(title: "Tüm yerel dallar (\(repo.branches.count))") {
            ForEach(repo.branches) { branch in
                HStack(spacing: 8) {
                    Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                    Text(branch.name)
                    if branch.name == repo.defaultBranch {
                        Text("varsayılan").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(branchState(branch))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func branchState(_ branch: BranchInfo) -> String {
        var parts: [String] = []
        if repo.remotes.isEmpty {
            parts.append("uzak depo yok")
        } else if !branch.existsOnRemote {
            parts.append(branch.upstreamGone ? "uzak dalı silinmiş" : "yalnızca yerelde")
        } else if let upstream = branch.upstream {
            parts.append(upstream)
        }
        if branch.ahead > 0 { parts.append("\(branch.ahead) ileride") }
        if branch.behind > 0 { parts.append("\(branch.behind) geride") }
        if branch.uniqueCommits > 0 { parts.append("\(branch.uniqueCommits) commit hiçbir uzak depoda yok") }
        if branch.mergedIntoDefault { parts.append("birleştirilmiş") }
        if let date = branch.lastCommit { parts.append(Format.ago(date)) }
        return parts.joined(separator: " · ")
    }

    private var remotes: some View {
        Card(title: "Uzak depolar") {
            ForEach(repo.remotes, id: \.name) { remote in
                HStack(spacing: 8) {
                    Text(remote.name).fontWeight(.medium)
                    Text(remote.url)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.level == .clean ? "info.circle" : finding.level.symbol)
                .foregroundStyle(finding.level == .clean ? Color.secondary : finding.level.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.text)
                    .fontWeight(finding.level == .critical ? .medium : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = finding.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// Başlıklı, yuvarlak köşeli bölüm kutusu.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        }
    }
}
