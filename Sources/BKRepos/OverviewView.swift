import SwiftUI
import BKReposCore

struct OverviewView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kaybolabilecek iş").font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    ForEach(RiskLevel.allCases.reversed(), id: \.self) { level in
                        CountCard(level: level, count: state.count(level), scanned: state.scannedThisSession)
                    }
                }

                if state.isScanning && !state.scannedThisSession {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.progress.isEmpty ? "Taranıyor…" : "Taranıyor… \(state.progress)")
                            .foregroundStyle(.secondary)
                    }
                }

                let risky = state.reports.filter { $0.level != .clean }
                if !risky.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("İlgilenilmesi gerekenler").font(.headline)
                        ForEach(risky) { report in
                            Button {
                                state.page = .repo(report.repo.path)
                            } label: {
                                RiskyRepoCard(report: report)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if state.scannedThisSession {
                    ContentUnavailableView(
                        state.reports.isEmpty ? "Depo bulunamadı" : "Her şey güvende",
                        systemImage: state.reports.isEmpty ? "questionmark.folder" : "checkmark.seal",
                        description: Text(state.reports.isEmpty
                            ? "Aranan klasörler: \(state.config.roots.joined(separator: ", ")). Menüden ayarlar dosyasını açıp `roots` listesini düzenleyebilirsiniz."
                            : "Commit'lenmemiş, push'lanmamış ya da unutulmuş bir iş yok.")
                    )
                    .frame(maxWidth: .infinity)
                }

                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        guard state.scannedThisSession else { return "Depolar taranıyor…" }
        return "\(state.reports.count) depo tarandı. Uzak depoların durumu son getirilen (fetch) bilgiye göredir; tarama ağa çıkmaz."
    }

    private var footer: String {
        var parts: [String] = []
        if let last = state.lastScan {
            parts.append("Son tarama: \(last.formatted(date: .abbreviated, time: .shortened)) (\(Format.ago(last)))")
        }
        if state.config.reminderEnabled {
            parts.append("Günlük hatırlatma: \(state.config.reminderTime)")
        }
        parts.append("Klasörler: \(state.config.roots.joined(separator: ", "))")
        return parts.joined(separator: " · ")
    }
}

struct CountCard: View {
    let level: RiskLevel
    let count: Int
    let scanned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(level.title, systemImage: level.symbol)
                .font(.headline)
                .foregroundStyle(level.color)
            Text(scanned ? "\(count)" : "—")
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private var caption: String {
        switch level {
        case .critical: return "Tek kopyası bu bilgisayarda olan ya da günlerdir bekleyen iş"
        case .warning: return "Yeni değişiklikler, stash'ler, silinebilecek dallar ve çalışma ağaçları"
        case .clean: return "Her şeyi commit'lenmiş ve push'lanmış depolar"
        }
    }
}

struct RiskyRepoCard: View {
    let report: RepoReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: report.level.symbol)
                .font(.title3)
                .foregroundStyle(report.level.color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(report.repo.name).font(.headline)
                    Text(report.repo.headDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let shown = report.findings.filter { $0.level != .clean }
                ForEach(shown.prefix(3)) { finding in
                    Text(finding.text)
                        .font(.callout)
                        .foregroundStyle(finding.level == .critical ? .primary : .secondary)
                        .lineLimit(2)
                }
                if shown.count > 3 {
                    Text("… ve \(shown.count - 3) bulgu daha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            RiskBadge(level: report.level)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .contentShape(Rectangle())
    }
}
