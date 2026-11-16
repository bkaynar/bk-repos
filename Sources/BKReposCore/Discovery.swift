import Foundation

public struct DiscoveryResult: Equatable, Sendable {
    /// Ana depo klasörleri.
    public var repos: [String] = []
    /// `.git` dosyası var ama gösterdiği git klasörü yok: git'in tanımadığı kopuk çalışma ağaçları.
    public var orphans: [String] = []
}

/// `.git` girdisinin ne olduğunu git çalıştırmadan belirler.
enum GitEntry: Equatable {
    case none
    /// Normal depo (`.git` bir klasör).
    case repository
    /// Bağlı çalışma ağacı; ilişkili değer ana deponun yolu (belirlenebildiyse).
    case linkedWorktree(mainRepo: String?)
    case submodule
    /// `.git` dosyasının gösterdiği yer yok.
    case orphan(pointer: String)

    static func classify(_ directory: String) -> GitEntry {
        let fm = FileManager.default
        let dotGit = directory + "/.git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return .none }
        if isDir.boolValue { return .repository }
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let pointer = Parsers.gitdirPointer(contents) else { return .none }
        let gitdir = pointer.hasPrefix("/") ? pointer : directory + "/" + pointer
        guard fm.fileExists(atPath: gitdir) else { return .orphan(pointer: pointer) }
        // Bağlı çalışma ağaçlarının git klasöründe ortak depoyu gösteren `commondir` dosyası bulunur.
        guard let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) else { return .submodule }
        let relative = common.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDir = Paths.canonical(relative.hasPrefix("/") ? relative : gitdir + "/" + relative)
        guard (commonDir as NSString).lastPathComponent == ".git" else { return .linkedWorktree(mainRepo: nil) }
        return .linkedWorktree(mainRepo: (commonDir as NSString).deletingLastPathComponent)
    }
}

public enum Discovery {
    /// Kök klasörlerin altındaki git depolarını bulur. Bağlı çalışma ağaçları ayrı depo sayılmaz;
    /// ana depoları listeye eklenir ve orada çalışma ağacı olarak gösterilir.
    public static func find(config: Config) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        let ignored = config.expandedIgnoredRepos
        let skip = Set(config.skipDirectories)
        let fm = FileManager.default

        func addRepo(_ path: String) {
            let key = Paths.canonical(path)
            guard !ignored.contains(key), seen.insert(key).inserted else { return }
            result.repos.append(path)
        }

        func visit(_ directory: String, depth: Int) {
            switch GitEntry.classify(directory) {
            case .repository: addRepo(directory)
            case .linkedWorktree(let main): if let main { addRepo(main) }
            case .orphan: result.orphans.append(directory)
            case .submodule, .none: break
            }
            guard depth < config.maxDepth,
                  let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() where !name.hasPrefix(".") && !skip.contains(name) {
                let child = directory + "/" + name
                // Sembolik bağlantılar izlenmez (döngü ve çift sayım olmasın).
                guard let type = try? fm.attributesOfItem(atPath: child)[.type] as? FileAttributeType,
                      type == .typeDirectory else { continue }
                visit(child, depth: depth + 1)
            }
        }

        for root in config.expandedRoots {
            visit(root.path, depth: 0)
        }
        result.repos.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }
}
