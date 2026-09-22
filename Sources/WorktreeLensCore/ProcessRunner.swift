import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], currentDirectory: String?) throws -> ProcessResult
}

public struct LocalProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], currentDirectory: String?) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory.map(URL.init(fileURLWithPath:))
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

public enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "Executable not found: \(path)"
        case .failed(let message): return message
        }
    }
}
