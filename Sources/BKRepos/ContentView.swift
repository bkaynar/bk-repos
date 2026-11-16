import SwiftUI
import BKReposCore

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem {
                        if state.isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(state.progress.isEmpty ? "Taranıyor…" : state.progress)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    ToolbarItem {
                        Button {
                            state.scan()
                        } label: {
                            Label("Şimdi tara", systemImage: "arrow.clockwise")
                        }
                        .help("Tüm depoları yeniden tara (ağa çıkmaz)")
                        .disabled(state.isScanning || state.busyRepo != nil)
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 580)
        .confirmationDialog(
            state.pending?.confirmation.title ?? "",
            isPresented: Binding(get: { state.pending != nil }, set: { if !$0 { state.pending = nil } }),
            presenting: state.pending
        ) { pending in
            Button(pending.confirmation.confirmLabel) { state.confirmPending() }
            Button("Vazgeç", role: .cancel) { state.pending = nil }
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .alert(
            state.alert?.title ?? "",
            isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } }),
            presenting: state.alert
        ) { _ in
            Button("Tamam", role: .cancel) { state.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.page {
        case .overview:
            OverviewView(state: state)
        case .repo(let path):
            if let report = state.report(path) {
                RepoDetailView(state: state, report: report)
            } else {
                OverviewView(state: state)
            }
        }
    }
}

struct Sidebar: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: Binding<Page?>(get: { state.page }, set: { if let page = $0 { state.page = page } })) {
            Label("Genel Bakış", systemImage: "square.grid.2x2")
                .tag(Page.overview)

            Section("Depolar") {
                ForEach(state.filteredReports) { report in
                    RepoRow(report: report)
                        .tag(Page.repo(report.repo.path))
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $state.search, placement: .sidebar, prompt: "Depo ara")
        .overlay {
            if state.scannedThisSession && state.filteredReports.isEmpty && !state.search.isEmpty {
                Text("Eşleşen depo yok").foregroundStyle(.secondary)
            }
        }
    }
}

struct RepoRow: View {
    let report: RepoReport

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: report.level.symbol)
                .foregroundStyle(report.level.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.repo.name).lineLimit(1)
                Text(report.repo.headDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            RiskBadge(level: report.level)
        }
        .padding(.vertical, 2)
    }
}

/// Risk düzeyini gösteren küçük etiket.
struct RiskBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(level.color)
            .background(Capsule().fill(level.color.opacity(0.16)))
            .fixedSize()
    }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .clean: return .green
        }
    }

    var symbol: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .clean: return "checkmark.circle.fill"
        }
    }
}

extension RepoStatus {
    /// "main → origin/main" ya da "ayrık HEAD abc1234".
    var headDescription: String {
        if scanError != nil { return "taranamadı" }
        switch status.head {
        case .branch(let name): return name
        case .detached(let oid): return "ayrık HEAD \(oid)"
        }
    }
}
