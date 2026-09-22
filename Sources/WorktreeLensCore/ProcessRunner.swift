import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval?) throws -> ProcessResult
}

public extension ProcessRunning {
    func run(_ executable: String, arguments: [String], currentDirectory: String?) throws -> ProcessResult {
        try run(executable, arguments: arguments, currentDirectory: currentDirectory, timeout: nil)
    }
}

public struct LocalProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval? = nil) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory.map(URL.init(fileURLWithPath:))
        process.standardOutput = output
        process.standardError = errorPipe

        // Drain both pipes while the child runs. Waiting first can deadlock when either
        // pipe fills its kernel buffer before the child exits.
        let group = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stdoutData = data
            lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            stderrData = data
            lock.unlock()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            group.wait()
            throw error
        }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        process.waitUntilExit()
        group.wait()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

public enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case failed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "Executable not found: \(path)"
        case .failed(let message): return message
        case .timedOut(let executable): return "Process timed out: \(executable)"
        }
    }
}
