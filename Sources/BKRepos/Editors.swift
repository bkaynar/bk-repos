import AppKit

/// Kurulu olduğu paket kimliğinden anlaşılan kod editörü.
struct Editor: Identifiable, Hashable {
    let name: String
    let url: URL

    var id: String { url.path }
}

@MainActor
enum Editors {
    /// Sunulabilecek editörler ve paket kimlikleri. Yalnızca kurulu olanlar gösterilir.
    static let known: [(name: String, bundleIDs: [String])] = [
        ("Antigravity IDE", ["com.google.antigravity-ide", "com.google.antigravity"]),
        ("VS Code", ["com.microsoft.VSCode"]),
        ("Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("Android Studio", ["com.google.android.studio"]),
        ("Xcode", ["com.apple.dt.Xcode"]),
    ]

    static func installed() -> [Editor] {
        known.compactMap { entry in
            entry.bundleIDs
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .first
                .map { Editor(name: entry.name, url: $0) }
        }
    }

    static func open(_ path: String, with editor: Editor) {
        open(path, applicationURL: editor.url)
    }

    static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        open(path, applicationURL: terminal)
    }

    static func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func open(_ path: String, applicationURL: URL) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
