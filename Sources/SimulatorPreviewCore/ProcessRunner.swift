import Foundation

public struct ProcessDataResult: Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public var combinedOutput: String {
        [stdoutString, stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct CommandFailure: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public struct ProcessRunner {
    public init() {}

    public func capture(
        _ command: String,
        _ args: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        maxBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        let result = try runCapturing(command, args, cwd: cwd, stdin: stdin, maxBytes: maxBytes)
        guard result.exitCode == 0 else {
            throw CommandFailure(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    public func captureData(
        _ command: String,
        _ args: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        maxBytes: Int = 4 * 1024 * 1024
    ) throws -> Data {
        let result = try runCapturingData(command, args, cwd: cwd, stdin: stdin, maxBytes: maxBytes)
        guard result.exitCode == 0 else {
            throw CommandFailure(message: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    public func runCapturing(
        _ command: String,
        _ args: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        maxBytes: Int = 8 * 1024 * 1024
    ) throws -> ProcessResult {
        let result = try runCapturingData(command, args, cwd: cwd, stdin: stdin, maxBytes: maxBytes)
        return ProcessResult(
            exitCode: result.exitCode,
            stdout: result.stdoutString,
            stderr: result.stderrString
        )
    }

    public func runCapturingData(
        _ command: String,
        _ args: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        maxBytes: Int = 8 * 1024 * 1024
    ) throws -> ProcessDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = cwd

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = Pipe()
        if stdin != nil {
            process.standardInput = inputPipe
        }

        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            stdoutData.append(data)
            lock.unlock()
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            stderrData.append(data)
            lock.unlock()
        }

        try process.run()
        if let stdin {
            inputPipe.fileHandleForWriting.write(stdin)
            inputPipe.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let finalOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let finalError = errorPipe.fileHandleForReading.readDataToEndOfFile()

        lock.lock()
        stdoutData.append(finalOutput)
        stderrData.append(finalError)
        let output = stdoutData
        let error = stderrData
        lock.unlock()

        guard output.count + error.count <= maxBytes else {
            throw CommandFailure(message: "\(command) output exceeded \(maxBytes) bytes")
        }

        return ProcessDataResult(
            exitCode: process.terminationStatus,
            stdout: output,
            stderr: error
        )
    }
}
