import AppKit
import SwiftUI
import BKReposCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum Keys {
        static let lastReminderDay = "lastReminderDay"
    }

    let state = AppState()
    private var window: NSWindow?
    private var timer: Timer?
    private var notificationsAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
        }

        // Dakikada bir ve uyku sonrası: arka plan taraması ya da günlük hatırlatma zamanı geldi mi diye bakılır.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.tick() }
        }

        // Masaüstünden ya da Finder'dan açıldıysa pencere gösterilir; girişte otomatik başladıysa sessiz kalır.
        if CommandLine.arguments.contains("--pencere") || !launchedAtLogin {
            showWindow()
        } else {
            // Giriş sırasında sistemi yormamak için ilk tarama biraz sonra.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.tick() }
        }
    }

    /// Uygulama zaten açıkken simgesine yeniden tıklanırsa pencere öne gelir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private var launchedAtLogin: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Yedek kural: bilgisayar birkaç dakika önce açıldıysa girişte başlatılmış sayılır.
        return ProcessInfo.processInfo.systemUptime < 300
    }

    // MARK: Zamanlanmış tarama ve günlük hatırlatma

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// Bugünün hatırlatma saati geçti ve bugün henüz hatırlatılmadı.
    private var isReminderDue: Bool {
        let config = state.config
        guard config.reminderEnabled else { return false }
        let now = Date()
        let time = config.reminderHourMinute
        guard let due = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now),
              now >= due else { return false }
        return UserDefaults.standard.string(forKey: Keys.lastReminderDay) != Self.dayKey(now)
    }

    func tick() {
        guard !state.isScanning, state.busyRepo == nil else { return }
        let reminderDue = isReminderDue
        guard reminderDue || state.isScanDue else { return }
        // Hatırlatma her zaman taze bir taramanın sonucuna göre verilir.
        state.scan { [weak self] in
            guard let self, reminderDue else { return }
            UserDefaults.standard.set(Self.dayKey(Date()), forKey: Keys.lastReminderDay)
            let count = self.state.criticalCount
            guard count > 0 else { return }
            if self.notificationsAllowed {
                self.postReminder(count: count, names: self.state.criticalNames)
            } else {
                // Bildirim izni yoksa pencere doğrudan açılır.
                self.showWindow()
            }
        }
    }

    private func postReminder(count: Int, names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "\(count) projede kaybolabilecek iş var"
        content.body = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : "")
            + ". Ayrıntılar için tıklayın."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "gunluk-hatirlatma", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in self.showWindow() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(state: state)))
            window.title = "BK Repos"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("AnaPencere")
            self.window = window
        }
        if !state.scannedThisSession && !state.isScanning { state.scan() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
