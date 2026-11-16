import AppKit
import SwiftUI
import BKReposCore

/// Geliştirme yardımcısı: `BKRepos --anlik-goruntu <dosya.png> [--depo <ad>]`.
/// Depoları tarar (salt okunur), pencere içeriğini ekranda göstermeden PNG'ye çizer ve çıkar.
/// Bildirim izni istemez, giriş öğesi kaydetmez, menü çubuğuna simge koymaz.
@MainActor
enum Snapshot {
    static func run(output: String, repoName: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let state = AppState(persistent: false)
        state.scan()
        while state.isScanning || !state.scannedThisSession {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let repoName, let report = state.reports.first(where: { $0.repo.name == repoName }) {
            state.page = .repo(report.repo.path)
        }

        let size = NSSize(width: 1040, height: 700)
        // Ekran dışı çizimde pencere arka planı boyanmadığı için arka plan elle verilir.
        let host = NSHostingView(rootView: ContentView(state: state).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("Görüntü alınamadı\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: output))
            print("Anlık görüntü: \(output)")
        } catch {
            FileHandle.standardError.write(Data("Yazılamadı: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
