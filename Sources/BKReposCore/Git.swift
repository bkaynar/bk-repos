import Foundation

/// Uygulamanın çalıştırabildiği, depoyu DEĞİŞTİREN git komutlarının tamamı.
/// Buraya eklenmeyen hiçbir değiştirici komut çalıştırılamaz: `Git.read` yalnızca salt okunur
/// alt komutları kabul eder, `Git.mutate` ise yalnızca bu türü alır.
public enum GitMutation: Equatable, Sendable {
    case fetchAll
    case push
    case removeWorktree(path: String)
    case deleteMergedBranch(name: String)

    public var arguments: [String] {
        switch self {
        case .fetchAll: return ["fetch", "--all", "--prune"]
        // Düz push: zorlama (force) bayrağı hiçbir zaman eklenmez.
        case .push: return ["push"]
        // `--force` yok: çalışma ağacı kirliyse git kendisi de reddeder.
        case .removeWorktree(let path): return ["worktree", "remove", path]
        // Küçük `-d`: birleştirilmemiş dalı git kendisi de silmez. `-D` hiçbir zaman kullanılmaz.
        case .deleteMergedBranch(let name): return ["branch", "-d", "--", name]
        }
    }

    /// Ağa çıkan komutlar daha uzun bekler.
    var timeout: TimeInterval {
        switch self {
        case .fetchAll, .push: return 180
        case .removeWorktree, .deleteMergedBranch: return 60
        }
    }
}

public enum Git {
    public static let executable = "/usr/bin/git"

    /// `GIT_OPTIONAL_LOCKS=0`: `git status` index.lock almaz, açık bir IDE ya da başka bir git işlemiyle çakışmaz.
    /// `LC_ALL=C`: çıktılar dilden bağımsız ayrıştırılır. `GIT_TERMINAL_PROMPT=0`: parola sorup takılmaz.
    static let environment = [
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// Salt okunur sayılan komut başlangıçları. `read` bunların dışındaki her şeyi çalıştırmadan reddeder.
    static let readOnlyPrefixes: [[String]] = [
        ["status"], ["log"], ["rev-parse"], ["rev-list"], ["for-each-ref"], ["symbolic-ref", "--short"],
        ["branch", "--list"], ["stash", "list"], ["worktree", "list"], ["remote", "-v"], ["config", "--get"],
    ]

    public static func isReadOnly(_ arguments: [String]) -> Bool {
        readOnlyPrefixes.contains { prefix in
            arguments.count >= prefix.count && Array(arguments.prefix(prefix.count)) == prefix
        }
    }

    /// Salt okunur bir git komutu çalıştırır.
    public static func read(_ arguments: [String], in directory: String, timeout: TimeInterval = 20) -> ShellOutput {
        guard isReadOnly(arguments) else {
            return ShellOutput(
                status: -1, stdout: "",
                stderr: "Salt okunur olmayan komut reddedildi: git \(arguments.joined(separator: " "))",
                timedOut: false
            )
        }
        return Shell.run(executable, ["-C", directory] + arguments, environment: environment, timeout: timeout)
    }

    /// Değiştirici komutların tek giriş noktası. Ön koşullar `Actions` içinde denetlenir.
    static func mutate(_ mutation: GitMutation, in directory: String) -> ShellOutput {
        Shell.run(executable, ["-C", directory] + mutation.arguments, environment: environment, timeout: mutation.timeout)
    }
}
