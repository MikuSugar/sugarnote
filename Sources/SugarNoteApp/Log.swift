import Foundation

/// 应用日志。
///
/// 为什么不只用 `NSLog`：实测这个 App 的输出进不了统一日志（`log show --predicate
/// 'process == "sugarnote"'` 一直是空的），排查问题时等于没有。写文件最可靠，
/// 用户也能直接把内容贴出来。
///
/// 落在 `~/Library/Logs/sugarnote.log`，超过 512KB 就从头截断，不会无限长。
enum Log {

    static let url: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        let directory = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sugarnote.log")
    }()

    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        guard let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default

        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > maxBytes {
            try? manager.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
