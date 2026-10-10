// Core/Sources/PortmasterMCP/HandoffLauncher.swift
import Darwin
import Foundation

/// The process seam a handoff needs and the docker path does not: the brief on
/// stdin, a real working directory, a pid back for the chain, and the ability
/// to terminate a spawn whose bookkeeping then refused it. `ProcessRunning` is
/// deliberately not widened — it nulls stdin (spec amendment 7) and its other
/// callers have no use for any of this.
public protocol HandoffLaunching: Sendable {
    /// Absolute path of `executable`, searched on `path` (`$PATH` when nil),
    /// or nil when it is not installed — the fact §6 requires the failure to
    /// carry.
    func resolve(_ executable: String, path: String?) -> String?
    /// Starts the process with `stdinText` written to its stdin and stdin then
    /// closed (EOF after the brief), in `workingDirectory`. Returns the pid
    /// without waiting for exit — the agent runs for hours.
    func launch(
        executable: String, arguments: [String],
        workingDirectory: String, stdinText: String
    ) throws -> Int32
    func terminate(pid: Int32)
}

public struct SystemHandoffLauncher: HandoffLaunching {
    public init() {}

    public func resolve(_ executable: String, path: String?) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        let search = path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in search.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func launch(
        executable: String, arguments: [String],
        workingDirectory: String, stdinText: String
    ) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            throw MCPToolError(
                message: "The working directory \(workingDirectory) no longer exists."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MCPToolError(
                message: "Could not start \(executable): \(error.localizedDescription)"
            )
        }
        do {
            // Brief, then EOF: the agent reads its prompt from stdin and keeps
            // its own TTY for the conversation (spec §6). `contentsOf:` is the
            // throwing write — the plain `write(_:)` swallows failures as an
            // ObjC exception the catch below could never see.
            try input.fileHandleForWriting.write(contentsOf: Data(stdinText.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw MCPToolError(
                message: "Could not deliver the brief to \(executable): \(error.localizedDescription)"
            )
        }
        let pid = process.processIdentifier
        // Reap without waiting: the task's strong capture keeps the `Process`
        // alive until the child exits, so no zombie and no blocked tool call.
        Task.detached(priority: .utility) { process.waitUntilExit() }
        return pid
    }

    public func terminate(pid: Int32) {
        kill(pid, SIGTERM)
    }
}
