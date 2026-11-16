import Foundation

public struct ShellOutput: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }

    /// Kullanıcıya gösterilecek hata metni: git'in kendi çıktısı.
    public var errorText: String {
        if timedOut { return "Komut zaman aşımına uğradı." }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "Komut \(status) koduyla bitti." : out
    }
}

public enum Shell {
    /// Finder'dan açılan uygulamaların PATH'i dar olduğu için alt süreçlere genişletilmiş PATH verilir
    /// (git-lfs, kimlik yardımcıları gibi araçlar Homebrew altında olabilir).
    static let searchPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    @discardableResult
    public static func run(
        _ executable: String, _ arguments: [String],
        environment extra: [String: String] = [:], timeout: TimeInterval = 30
    ) -> ShellOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellOutput(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let timedOut = Flag()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        timer.resume()

        // stderr ayrı iş parçacığında okunur; aksi halde dolan bir boru süreci kilitleyebilir.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer.cancel()

        return ShellOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut.isSet
        )
    }
}

/// İş parçacıkları arasında paylaşılan basit bayrak.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
