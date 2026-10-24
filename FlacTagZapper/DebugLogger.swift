import Foundation
import Combine

enum LogLevel {
    case info
    case warning
    case error
}

struct ZipLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
}

final class ZipDebugLog: ObservableObject {
    static let shared = ZipDebugLog()
    private init() {}

    @Published private(set) var entries: [ZipLogEntry] = []

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    func log(_ message: String, level: LogLevel = .info) {
        #if DEBUG
        print("[FlacTagZapper] \(message)")
        #endif
        DispatchQueue.main.async {
            self.entries.append(ZipLogEntry(timestamp: Date(), level: level, message: message))
        }
    }

    var textDump: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { entry in
            let prefix: String
            switch entry.level {
            case .info: prefix = ""
            case .warning: prefix = "WARNING: "
            case .error: prefix = "ERROR: "
            }
            return "[\(formatter.string(from: entry.timestamp))] \(prefix)\(entry.message)"
        }.joined(separator: "\n")
    }
}
