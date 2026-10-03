// SubprocessRunner: the one place the provider runs a command.
//
// The argument type is the whole safety property: a value goes in as one element
// of an argument list, so nothing in it can be read as a flag, a path, or a
// command. There is no shell anywhere in this path, so shell metacharacters in a
// container id are characters.
import Darwin
import Foundation

/// What one command left behind: the status it exited with, and what it said on
/// stderr.
public struct CommandOutcome: Sendable {
    /// Exit status, or -1 when the process was terminated instead of exiting on
    /// its own. `-1` never comes from a program; it means the timeout stopped it,
    /// and `standardError` then explains that rather than quoting docker.
    public let exitCode: Int32
    public let standardError: String

    public init(exitCode: Int32, standardError: String) {
        self.exitCode = exitCode
        self.standardError = standardError
    }
}

/// Runs one command with an argument list, never a command string.
///
/// The argument type is the whole safety property: a container id goes in as
/// one element, so nothing in it can be read as a flag, a path, or a command.
/// There is no shell anywhere in this path, so shell metacharacters in an id are
/// just characters.
public protocol ProcessRunning: Sendable {
    /// - Throws: `MCPToolError` when the process could not be started at all.
    ///   A non-zero exit is an outcome, not an error: the caller reports what the
    ///   command said.
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutcome
}

/// The real runner: `Process` with `executableURL` and `arguments` set
/// separately, exactly as `DockerCollector` runs its sampling passes.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String, arguments: [String], timeout: TimeInterval
    ) async throws -> CommandOutcome {
        // `Process` blocks, so it runs off the cooperative pool: a blocked tool
        // call must not take a thread a sibling tool call needs.
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // stdout is docker echoing the id back, which we already know.
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            process.qualityOfService = .utility

            do {
                try process.run()
            } catch {
                throw MCPToolError(
                    message: "Could not start \(executable): \(error.localizedDescription)"
                )
            }

            // A stopped-but-unresponsive daemon makes `docker stop` hang, and a
            // tool call must not hang with it.
            let terminate = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            let kill = DispatchWorkItem {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout, execute: terminate
            )
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout + 2, execute: kill
            )
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            terminate.cancel()
            kill.cancel()

            guard process.terminationReason != .uncaughtSignal else {
                return CommandOutcome(
                    exitCode: -1,
                    standardError: "\(URL(fileURLWithPath: executable).lastPathComponent) was "
                        + "terminated after \(Int(timeout))s without answering."
                )
            }
            return CommandOutcome(
                exitCode: process.terminationStatus,
                standardError: String(data: data, encoding: .utf8) ?? ""
            )
        }.value
    }
}
