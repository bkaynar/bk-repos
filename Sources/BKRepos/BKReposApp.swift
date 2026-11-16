import AppKit
import ServiceManagement
import SwiftUI
import BKReposCore

@main
enum Main {
    static func main() {
        // Geliştirme yardımcısı: pencereyi ekranda göstermeden PNG'ye çizer (bkz. Snapshot.swift).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--anlik-goruntu"), index + 1 < arguments.count {
            let repoName = arguments.firstIndex(of: "--depo").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            MainActor.assumeIsolated { Snapshot.run(output: arguments[index + 1], repoName: repoName) }
            return
        }
        BKReposApp.main()
    }
}

struct BKReposApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state, appDelegate: appDelegate)
        } label: {
            MenuBarLabel(state: appDelegate.state)
        }
    }
}

/// Menü çubuğu simgesi; Kritik depo varsa sayısı yanında yazar.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        if state.criticalCount > 0 {
            Image(systemName: "arrow.triangle.branch")
            Text("\(state.criticalCount)")
        } else {
            Image(systemName: "arrow.triangle.branch")
        }
    }
}

struct MenuContent: View {
    let state: AppState
    let appDelegate: AppDelegate

    var body: some View {
        Text(state.menuSummary)
        if let last = state.lastScan {
            Text("Son tarama: \(Format.ago(last))")
        }
        Divider()
        Button("Pencereyi aç") { appDelegate.showWindow() }
        Button("Şimdi tara") { state.scan() }
            .disabled(state.isScanning || state.busyRepo != nil)
        Divider()
        Toggle("Girişte otomatik başlat", isOn: Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.setEnabled($0) }
        ))
        Button("Ayarlar dosyasını aç…") {
            Config.createFileIfMissing()
            Shell.run("/usr/bin/open", ["-t", Config.fileURL.path], timeout: 10)
        }
        Divider()
        Button("Çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Giriş öğesi ayarlanamadı"
            alert.informativeText = "\(error.localizedDescription)\n\nSistem Ayarları → Genel → Giriş Öğeleri bölümünden elle ekleyebilirsiniz."
            alert.runModal()
        }
    }
}
