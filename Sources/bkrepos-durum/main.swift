import Foundation
import BKReposCore

// Hiçbir şeyi DEĞİŞTİRMEZ ve ağa çıkmaz. Uygulamanın göstereceği bulguları terminalde listeler.
// Kullanım: bkrepos-durum [--kisa]   (--kisa: yalnızca depo adları ve risk düzeyleri)

let short = CommandLine.arguments.contains("--kisa")
let config = Config.load()
let started = Date()
let isTerminal = isatty(fileno(stderr)) != 0

let reports = RepoScanner.scanAll(config: config) { done, total, name in
    guard isTerminal else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[K… \(done)/\(total) \(name)".utf8))
}
if isTerminal { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

func mark(_ level: RiskLevel) -> String {
    switch level {
    case .critical: return "!!"
    case .warning: return " !"
    case .clean: return " ·"
    }
}

for level in RiskLevel.allCases.reversed() {
    let group = reports.filter { $0.level == level }
    guard !group.isEmpty else { continue }
    print("\n## \(level.title) (\(group.count))")
    for report in group {
        let repo = report.repo
        var head: String
        switch repo.status.head {
        case .branch(let name): head = name
        case .detached(let oid): head = "ayrık HEAD \(oid)"
        }
        if let upstream = repo.status.upstream {
            head += " → \(upstream)"
            if let ahead = repo.status.ahead, let behind = repo.status.behind {
                head += " (+\(ahead) −\(behind))"
            } else {
                head += " (uzak dal yok)"
            }
        }
        if short {
            print("  [\(level.title)] \(repo.name)" + (repo.worktrees.isEmpty ? "" : " · \(repo.worktrees.count) çalışma ağacı"))
            continue
        }
        print("\n\(repo.name)  [\(head)]  \(Paths.abbreviatingHome(repo.path))")
        if let commit = repo.lastCommit {
            print("    son commit: \(Format.ago(commit.date)) · \(commit.subject)")
        }
        for finding in report.findings {
            print("  \(mark(finding.level)) \(finding.text)")
            if let detail = finding.detail, finding.level != .clean { print("       \(detail)") }
        }
        for worktree in repo.worktrees {
            print("     ↳ çalışma ağacı: \(Paths.abbreviatingHome(worktree.path))")
        }
    }
}

let counts = RiskLevel.allCases.reversed().map { level in
    "\(reports.filter { $0.level == level }.count) \(level.title.lowercased(with: Locale(identifier: "tr")))"
}
let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
print("\n\(reports.count) depo: \(counts.joined(separator: ", ")) (\(seconds) sn)")
if reports.isEmpty {
    print("Depo bulunamadı. Aranan klasörler: \(config.roots.joined(separator: ", "))")
}
