// lsof-based listening-port scanner.
// Invokes /usr/sbin/lsof with FIXED arguments (no interpolation), a timeout,
// and parses its machine-friendly field output (-F0pcn).
import Foundation

public final class LsofPortScanner: PortCollector {
    private let lsofPath = "/usr/sbin/lsof"
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func listeningPorts() -> [ListeningPort]? {
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: lsofPath)
        // Fixed argv — nothing user-controlled is ever interpolated here.
        proc.arguments = ["-w", "-nP", "-iTCP", "-sTCP:LISTEN", "-F0pcn"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice
        proc.qualityOfService = .utility

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Hard timeout: lsof scanning all sockets can stall on unusual FDs.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let stateLock = NSLock()
        let timedOut = DispatchWorkItem {
            let stillRunning = stateLock.withLock { proc.isRunning }
            if stillRunning {
                proc.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: timedOut
        )

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        timedOut.cancel()

        let status = proc.terminationStatus
        let wasKilled = proc.terminationReason == .uncaughtSignal

        guard !wasKilled else { return nil } // watchdog fired

        // Exit 1 legitimately means "no listening sockets".
        guard status == 0 || status == 1 else { return nil }

        return Self.parseFieldOutput(data)
    }

    // MARK: - Parsing

    /// Parse `lsof -F0pcn` output: NEWLINE-terminated records whose fields are
    /// NUL-separated, each field prefixed with a single letter:
    /// p(pid) c(command) n(name, e.g. *:5432 or 127.0.0.1:8080).
    /// A record is one FD; a process may emit several (v4+v6, multiple sockets).
    /// Splitting on NUL alone glues the record separator onto the next field
    /// ("\np987"), which silently dropped every pid after the first record —
    /// so both separators must split.
    static func parseFieldOutput(_ data: Data) -> [ListeningPort] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var results: [ListeningPort] = []
        var seen = Set<ListeningPort>()

        let fields = text.split { $0 == "\0" || $0 == "\n" }
        var currentPid: pid_t?
        var currentCmd: String?

        for field in fields {
            guard field.count >= 1 else { continue }
            let tag = field.first!
            let value = String(field.dropFirst())

            switch tag {
            case "p":
                currentPid = pid_t(value) ?? nil
                currentCmd = nil
            case "c":
                currentCmd = value
            case "n":
                guard let pid = currentPid else { continue }
                guard let (port, host) = Self.parseEndpoint(value) else { continue }
                let row = ListeningPort(
                    port: port,
                    pid: pid,
                    processName: currentCmd ?? "pid \(pid)",
                    address: host,
                    processResolved: true
                )
                if seen.insert(row).inserted {
                    results.append(row)
                }
            default:
                break
            }
        }
        return results
    }

    /// Split "host:port" (or "[v6]:port") into components.
    static func parseEndpoint(_ s: String) -> (port: UInt16, host: String)? {
        // IPv6 literal: [::1]:8080
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            guard let port = UInt16(after.dropFirst()) else { return nil }
            return (port, host)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        guard let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (port, host.isEmpty ? "*" : host)
    }
}
