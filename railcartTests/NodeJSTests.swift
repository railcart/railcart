import Testing
import Foundation

struct NodeJSTests {

    @Test func nodeTestSuite() async throws {
        let bundle = Bundle.main
        // In test targets, Bundle.main points to the Xcode test runner.
        // Resolve paths relative to the source root via the project directory.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // railcartTests/
            .deletingLastPathComponent() // project root

        let nodeBinary = sourceRoot
            .appendingPathComponent("vendor/node/bin/node")
        let projectDir = sourceRoot
            .appendingPathComponent("nodejs-project")

        #expect(
            FileManager.default.fileExists(atPath: nodeBinary.path),
            "Node binary not found at \(nodeBinary.path) — run scripts/setup-node.sh first"
        )

        let process = Process()
        process.executableURL = nodeBinary
        process.arguments = ["--test", "src/**/*.test.js"]
        process.currentDirectoryURL = projectDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            Issue.record("Node.js tests failed (exit \(process.terminationStatus)):\n\(output)")
        }
    }
}
