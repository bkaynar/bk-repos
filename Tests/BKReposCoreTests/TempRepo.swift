import Foundation
import XCTest
@testable import BKReposCore

/// Testler kullanıcının depolarına dokunmaz; her şey geçici bir klasörde kurulur.
class TempRepoTestCase: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        // Kullanıcının genel git ayarları (imzalama, takma adlar…) testleri etkilemesin.
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BKReposTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = Paths.canonical(url.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Test deposu kurmak için git çalıştırır (çekirdekteki salt okunur çalıştırıcıdan bağımsız).
    @discardableResult
    func git(_ arguments: String..., in directory: String, date: Date? = nil) throws -> String {
        var env = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp
            env["GIT_COMMITTER_DATE"] = stamp
        }
        let output = Shell.run("/usr/bin/git", ["-C", directory] + arguments, environment: env, timeout: 30)
        if !output.succeeded {
            throw NSError(domain: "git", code: Int(output.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(output.errorText)",
            ])
        }
        return output.stdout
    }

    func makeDirectory(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func write(_ text: String, to relative: String, in repo: String, modified: Date? = nil) throws {
        let path = repo + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
    }

    /// Dosya yazar ve commit'ler.
    func commit(_ message: String, file: String = "dosya.txt", in repo: String, date: Date? = nil) throws {
        try write(message + "\n" + UUID().uuidString, to: file, in: repo)
        try git("add", "-A", in: repo)
        try git("commit", "-q", "-m", message, in: repo, date: date)
    }

    /// Tek commit'li, uzak deposu olmayan depo.
    func makeRepo(_ name: String, date: Date? = nil) throws -> String {
        let path = try makeDirectory(name)
        try git("init", "-q", "-b", "main", in: path)
        try commit("ilk commit", in: path, date: date)
        return path
    }

    /// Çıplak (bare) bir "uzak depo" ile eşitlenmiş depo. Ağ kullanılmaz; uzak depo yerel bir klasördür.
    func makeRepoWithRemote(_ name: String, date: Date? = nil) throws -> (repo: String, remote: String) {
        let remote = try makeDirectory("uzak/\(name).git")
        try git("init", "-q", "--bare", "-b", "main", in: remote)
        let repo = try makeRepo(name, date: date)
        try git("remote", "add", "origin", remote, in: repo)
        try git("push", "-q", "-u", "origin", "main", in: repo)
        return (repo, remote)
    }

    func branchExists(_ name: String, in repo: String) -> Bool {
        (try? git("rev-parse", "--verify", "-q", "refs/heads/" + name, in: repo)) != nil
    }

    func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    func levels(_ repo: RepoStatus, config: Config = Config()) -> RiskLevel {
        RepoReport(repo: repo, findings: Risk.evaluate(repo, config: config)).level
    }
}
