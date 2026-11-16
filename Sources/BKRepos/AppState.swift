import Foundation
import Observation
import BKReposCore

enum Page: Hashable {
    case overview
    case repo(String)
}

/// Onay bekleyen işlem.
struct PendingAction: Identifiable {
    let action: RepoAction
    let repoPath: String
    let confirmation: ActionConfirmation

    var id: String { repoPath + confirmation.title }
}

struct AlertInfo: Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}

@MainActor
@Observable
final class AppState {
    private enum Keys {
        static let lastScan = "lastScan"
    }

    var page: Page = .overview
    var search = ""
    var reports: [RepoReport] = []
    var isScanning = false
    var scannedThisSession = false
    var progress = ""
    /// Üzerinde işlem çalışan deponun yolu ve işlemin adı.
    var busyRepo: String?
    var busyText = ""
    /// Son başarılı işlemin kısa mesajı (depo yoluna göre).
    var lastActionMessage: [String: String] = [:]
    var pending: PendingAction?
    var alert: AlertInfo?
    private(set) var lastScan: Date?
    private(set) var config = Config.load()
    let editors = Editors.installed()

    /// Son tarama zamanı kalıcı olarak saklansın mı (anlık görüntü kipinde saklanmaz).
    private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        lastScan = persistent ? UserDefaults.standard.object(forKey: Keys.lastScan) as? Date : nil
    }

    // MARK: Hesaplananlar

    func count(_ level: RiskLevel) -> Int { reports.filter { $0.level == level }.count }
    var criticalCount: Int { count(.critical) }
    var criticalNames: [String] { reports.filter { $0.level == .critical }.map(\.repo.name) }

    var filteredReports: [RepoReport] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return reports }
        return reports.filter {
            $0.repo.name.localizedCaseInsensitiveContains(query) || $0.repo.path.localizedCaseInsensitiveContains(query)
        }
    }

    func report(_ path: String) -> RepoReport? { reports.first { $0.repo.path == path } }

    var isScanDue: Bool {
        guard let lastScan else { return true }
        return Date().timeIntervalSince(lastScan) >= Double(max(1, config.scanIntervalMinutes)) * 60
    }

    var menuSummary: String {
        if isScanning { return progress.isEmpty ? "Taranıyor…" : "Taranıyor… \(progress)" }
        if !scannedThisSession { return "Henüz taranmadı" }
        if reports.isEmpty { return "Depo bulunamadı" }
        if criticalCount == 0 && count(.warning) == 0 { return "\(reports.count) deponun hepsi temiz" }
        return "\(criticalCount) kritik, \(count(.warning)) uyarı, \(count(.clean)) temiz"
    }

    // MARK: Tarama

    /// Tüm depoları tarar. Yalnızca salt okunur git komutları çalışır; ağa çıkılmaz.
    func scan(completion: (() -> Void)? = nil) {
        guard !isScanning else { return }
        isScanning = true
        progress = ""
        config = Config.load()
        let config = self.config

        Task.detached(priority: .utility) {
            let found = RepoScanner.scanAll(config: config) { done, total, name in
                Task { @MainActor in
                    if self.isScanning { self.progress = "\(done)/\(total) \(name)" }
                }
            }
            await MainActor.run {
                self.reports = found
                self.isScanning = false
                self.scannedThisSession = true
                self.progress = ""
                let now = Date()
                self.lastScan = now
                if self.persistent { UserDefaults.standard.set(now, forKey: Keys.lastScan) }
                // Seçili depo artık yoksa genel bakışa dönülür.
                if case .repo(let path) = self.page, self.report(path) == nil { self.page = .overview }
                completion?()
            }
        }
    }

    // MARK: İşlemler

    /// Bir işlemi başlatır: engel varsa nedenini gösterir, yoksa onay ister.
    /// Getir (fetch) zaten açık bir düğme tıklamasıdır; ayrıca onay istenmez.
    func request(_ action: RepoAction, in report: RepoReport) {
        guard busyRepo == nil, !isScanning else { return }
        if let reason = Actions.blocker(action, repo: report.repo) {
            alert = AlertInfo(title: "Bu işlem şu an yapılamaz", message: reason)
            return
        }
        if action == .fetch {
            run(action, repoPath: report.repo.path)
        } else {
            pending = PendingAction(
                action: action, repoPath: report.repo.path,
                confirmation: Actions.confirmation(action, repo: report.repo)
            )
        }
    }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        run(pending.action, repoPath: pending.repoPath)
    }

    private func run(_ action: RepoAction, repoPath: String) {
        guard busyRepo == nil else { return }
        busyRepo = repoPath
        busyText = Self.busyText(action)
        lastActionMessage[repoPath] = nil
        let config = self.config
        let orphans = report(repoPath)?.repo.worktrees.filter(\.isOrphaned).map(\.path) ?? []

        Task.detached(priority: .userInitiated) {
            // `perform` komutu çalıştırmadan hemen önce depoyu yeniden tarar ve ön koşulu son kez denetler.
            let result = Actions.perform(action, repoPath: repoPath, config: config)
            let repo = RepoScanner.scan(path: repoPath, config: config, extraOrphans: orphans)
            let updated = RepoReport(repo: repo, findings: Risk.evaluate(repo, config: config))
            await MainActor.run {
                if let index = self.reports.firstIndex(where: { $0.repo.path == repoPath }) {
                    self.reports[index] = updated
                    self.reports = RepoScanner.sorted(self.reports)
                }
                self.busyRepo = nil
                self.busyText = ""
                if result.succeeded {
                    self.lastActionMessage[repoPath] = Self.successText(action)
                } else {
                    self.alert = AlertInfo(title: Self.failureTitle(action), message: result.message)
                }
            }
        }
    }

    private static func busyText(_ action: RepoAction) -> String {
        switch action {
        case .fetch: return "Getiriliyor…"
        case .push: return "Push'lanıyor…"
        case .removeWorktree: return "Çalışma ağacı kaldırılıyor…"
        case .deleteBranch: return "Dal siliniyor…"
        }
    }

    private static func successText(_ action: RepoAction) -> String {
        switch action {
        case .fetch: return "Uzak depolardan getirildi."
        case .push: return "Push'landı."
        case .removeWorktree(let path): return "Çalışma ağacı kaldırıldı: \((path as NSString).lastPathComponent)"
        case .deleteBranch(let name): return "Dal silindi: \(name)"
        }
    }

    private static func failureTitle(_ action: RepoAction) -> String {
        switch action {
        case .fetch: return "Getirilemedi"
        case .push: return "Push'lanamadı"
        case .removeWorktree: return "Çalışma ağacı kaldırılamadı"
        case .deleteBranch: return "Dal silinemedi"
        }
    }
}
