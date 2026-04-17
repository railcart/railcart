//
//  AppLogger.swift
//  railcart
//
//  File-backed application logger for debugging sync, bridge, and wallet operations.
//  Never logs sensitive information (keys, mnemonics, passwords, private keys).
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppLogger {
    nonisolated static let shared = AppLogger()

    /// Recent log entries for the UI (capped to avoid memory growth).
    private(set) var entries: [LogEntry] = []
    private let maxEntries = 2000

    let logFileURL: URL?
    private let fileHandle: FileHandle?
    nonisolated static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String

        var formatted: String {
            "[\(AppLogger.dateFormatter.string(from: timestamp))] [\(category)] \(message)"
        }
    }

    private nonisolated init() {
        let logDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("app.railcart.macos", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("railcart.log")
        logFileURL = logFile

        // Rotate if over 2 MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logFile)
        }

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()

        let startLine = "[\(Self.dateFormatter.string(from: Date()))] [system] Logger started — writing to \(logFile.path)\n"
        if let data = startLine.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(_ category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let line = entry.formatted + "\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
}

// MARK: - Environment Key

private struct AppLoggerKey: EnvironmentKey {
    static let defaultValue: AppLogger = .shared
}

extension EnvironmentValues {
    var appLogger: AppLogger {
        get { self[AppLoggerKey.self] }
        set { self[AppLoggerKey.self] = newValue }
    }
}
