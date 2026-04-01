//
//  NodeBridge.swift
//  railcart
//
//  Manages a Node.js child process and provides JSON-RPC communication over stdin/stdout.
//

import Foundation
import Observation

/// Errors from the Node.js bridge.
enum NodeBridgeError: LocalizedError {
    case notRunning
    case nodeNotFound
    case processExited(Int32)
    case timeout
    case remoteError(code: Int, message: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Node.js process is not running"
        case .nodeNotFound: "Node.js not found. Install via https://nodejs.org or brew install node"
        case .processExited(let code): "Node.js process exited with code \(code)"
        case .timeout: "Request timed out"
        case .remoteError(_, let message): message
        case .decodingError(let detail): "Failed to decode response: \(detail)"
        }
    }
}

/// A single pending request awaiting a response from Node.js.
private struct PendingRequest: Sendable {
    let continuation: CheckedContinuation<any Sendable, any Error>
}

/// Manages the Node.js child process and provides async Swift methods to call into it.
@MainActor
@Observable
final class NodeBridge {
    private(set) var isRunning = false
    private(set) var isReady = false
    private(set) var errorMessage: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var pendingRequests: [String: PendingRequest] = [:]
    private var eventHandlers: [String: [@Sendable (any Sendable) -> Void]] = [:]
    private var readBuffer = ""

    /// Resolve the bundled node binary inside the app's Resources.
    private static func bundledNodePath() -> String? {
        Bundle.main.path(forResource: "node", ofType: nil)
    }

    /// Resolve the bundled nodejs-project directory inside the app's Resources.
    private static func bundledProjectPath() -> String? {
        Bundle.main.path(forResource: "nodejs-project", ofType: nil)
    }

    /// Start the Node.js process.
    func start() async throws {
        guard !isRunning else { return }
        errorMessage = nil

        guard let nodePath = Self.bundledNodePath() else {
            let msg = "Bundled Node.js binary not found. Run: scripts/setup-node.sh then rebuild."
            errorMessage = msg
            throw NodeBridgeError.nodeNotFound
        }

        guard let projectPath = Self.bundledProjectPath() else {
            let msg = "Bundled nodejs-project not found. Rebuild the app."
            errorMessage = msg
            throw NodeBridgeError.nodeNotFound
        }

        AppLogger.shared.log("bridge", "Node binary: \(nodePath)")
        AppLogger.shared.log("bridge", "Project dir: \(projectPath)")

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = ["src/main.js"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["NODE_ENV"] = "production"
        proc.environment = env

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Handle process termination
        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.isReady = false
                let pending = self.pendingRequests
                self.pendingRequests.removeAll()
                for (_, req) in pending {
                    req.continuation.resume(throwing: NodeBridgeError.processExited(process.terminationStatus))
                }
            }
        }

        // Read stdout for bridge messages
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.handleStdoutData(str)
                }
            }
        }

        // Log stderr to AppLogger and Xcode console
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { @MainActor in
                        AppLogger.shared.log("node", trimmed)
                    }
                }
            }
        }

        try proc.run()
        isRunning = true

        // Wait for the "ready" event with a timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.onEvent("ready") { _ in
                        cont.resume()
                    }
                }
                self.isReady = true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw NodeBridgeError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Stop the Node.js process.
    func stop() {
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        isRunning = false
        isReady = false
    }

    /// Send a request to Node.js and await the typed response.
    func call<T: Decodable>(_ method: String, params: [String: any Sendable] = [:], as type: T.Type, timeout: Duration = .seconds(30)) async throws -> T {
        let raw = try await callRaw(method, params: params, timeout: timeout)

        let jsonData = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    /// Send a request and get back the raw result.
    func callRaw(_ method: String, params: [String: any Sendable] = [:], timeout: Duration = .seconds(30)) async throws -> any Sendable {
        guard isRunning else { throw NodeBridgeError.notRunning }

        let id = UUID().uuidString
        let request: [String: Any] = ["id": id, "method": method, "params": params]

        let result: any Sendable = try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = PendingRequest(continuation: cont)
            sendJSON(request)
        }

        return result
    }

    /// Register a handler for events from Node.js.
    func onEvent(_ name: String, handler: @escaping @Sendable (any Sendable) -> Void) {
        eventHandlers[name, default: []].append(handler)
    }

    // MARK: - Private

    private func sendJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var str = String(data: data, encoding: .utf8) else {
            return
        }
        str += "\n"
        stdinPipe?.fileHandleForWriting.write(str.data(using: .utf8)!)
    }

    private func handleStdoutData(_ data: String) {
        readBuffer += data
        let lines = readBuffer.split(separator: "\n", omittingEmptySubsequences: false)

        if data.hasSuffix("\n") {
            readBuffer = ""
        } else {
            readBuffer = String(lines.last ?? "")
        }

        let completeLines = data.hasSuffix("\n") ? lines : lines.dropLast()
        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            handleMessage(trimmed)
        }
    }

    private func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.shared.log("bridge", "Could not parse JSON: \(json.prefix(200))")
            return
        }

        // Event message (no id)
        if let event = obj["event"] as? String {
            let eventData: any Sendable = obj["data"] ?? [String: Any]()
            for handler in eventHandlers[event] ?? [] {
                handler(eventData)
            }
            return
        }

        // Response message (has id)
        guard let id = obj["id"] as? String,
              let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }

        if let error = obj["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown error"
            pending.continuation.resume(throwing: NodeBridgeError.remoteError(code: code, message: message))
        } else {
            let result: any Sendable = obj["result"] ?? NSNull()
            pending.continuation.resume(returning: result)
        }
    }
}
