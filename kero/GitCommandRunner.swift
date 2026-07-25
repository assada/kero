//
//  GitCommandRunner.swift
//  kero
//

import Foundation

nonisolated struct GitCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

/// Executes the system Git binary directly, without a shell, while draining
/// both output pipes concurrently.
nonisolated enum GitCommandRunner {
    static func run(
        _ arguments: [String],
        in directory: String,
        standardInput: Data? = nil,
        environmentOverrides: [String: String] = [:]
    ) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: directory,
            isDirectory: true
        )

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        environment.merge(environmentOverrides) { _, new in new }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        do {
            try process.run()
        } catch {
            return GitCommandResult(
                status: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8)
            )
        }

        let outputData = LockedData()
        let errorData = LockedData()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.value = stdout.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        if let standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        readers.wait()
        return GitCommandResult(
            status: process.terminationStatus,
            stdout: outputData.value,
            stderr: errorData.value
        )
    }

    private final class LockedData: @unchecked Sendable {
        var value = Data()
    }
}
