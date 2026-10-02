// Sleep assertions: which apps are keeping this Mac awake. macOS publishes
// the per-process power-assertion list through `pmset -g assertions` — the
// same supported-system-tool pattern as the lsof, nettop, and docker
// collectors (fixed argv, no interpolation, hard timeout). No private API.
import Foundation

/// One power assertion held by one process, as macOS attributes it.
public struct SleepAssertion: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let processName: String
    /// Assertion kind, e.g. "PreventUserIdleSystemSleep" or "UserIsActive".
    public let kind: String
    /// Named-assertion detail, e.g. "Screen Sharing" (nil when unnamed).
    public let detail: String?

    public init(pid: pid_t, processName: String, kind: String, detail: String?) {
        self.pid = pid
        self.processName = processName
        self.kind = kind
        self.detail = detail
    }

    public var id: String { "\(pid)-\(kind)-\(detail ?? "-")" }

    /// Assertion kinds that keep the machine or its display awake. macOS
    /// reports many more kinds (BackgroundTask, NetworkClientActive, …) that
    /// do not hold the machine awake, so the list stays filtered to these.
    public static let awakeKinds: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "PreventUserIdleDisplaySleep",
        "UserIsActive",
    ]

    /// Human label for the assertion kind, plain-language first.
    public var kindLabel: String {
        switch kind {
        case "PreventUserIdleSystemSleep": return "Preventing sleep"
        case "PreventSystemSleep": return "Preventing system sleep"
        case "PreventUserIdleDisplaySleep": return "Keeping the display on"
        case "UserIsActive": return "Simulating user activity"
        default: return kind
        }
    }
}

public protocol SleepAssertionProviding: Sendable {
    /// Current sleep-preventing assertions. nil = the source failed
    /// (missing tool, timeout) — distinct from an empty list.
    func sample() -> [SleepAssertion]?
}

/// Reads power assertions via /usr/bin/pmset -g assertions.
public final class PmsetAssertionCollector: SleepAssertionProviding, @unchecked Sendable {
    private let pmsetPath = "/usr/bin/pmset"
    private let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 6) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func sample() -> [SleepAssertion]? {
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pmsetPath)
        // Fixed argv — nothing user-controlled is ever interpolated here.
        proc.arguments = ["-g", "assertions"]

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

        let timedOut = DispatchWorkItem { [weak proc] in
            if let proc, proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: timedOut
        )

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        timedOut.cancel()

        guard proc.terminationReason != .uncaughtSignal else { return nil }
        guard proc.terminationStatus == 0 else { return nil }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.parse(text)
    }

    // Matches e.g.:
    //   pid 512(Screen Studio): [0x000012e5000192ab] 00:05:23 PreventUserIdleSystemSleep named: "Screen Sharing"
    //   pid 345(coreaudiod): [0x0000d00100019193] 00:00:00 PreventUserIdleSystemSleep named: "com.apple.audio.…"
    static let linePattern =
        #"^\s*pid\s+(\d+)\(([^)]*)\):\s*\[0x[0-9a-fA-F]+\]\s+\S+\s+([A-Za-z]+)(?:\s+named:\s+"([^"]*)")?"#

    /// Parse the "Listed by owning process" section of `pmset -g assertions`.
    /// Only awake kinds are kept; kernel-assertion and summary lines don't
    /// match the pid pattern and are skipped. Duplicate (pid, kind, detail)
    /// rows are deduped.
    static func parse(_ text: String) -> [SleepAssertion] {
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return [] }
        var results: [SleepAssertion] = []
        var seen = Set<String>()

        for line in text.split(separator: "\n") {
            let lineRange = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: String(line), range: lineRange) else { continue }

            func group(_ i: Int) -> String? {
                guard match.range(at: i).location != NSNotFound,
                      let r = Range(match.range(at: i), in: line) else { return nil }
                return String(line[r])
            }

            guard let pidString = group(1), let pid = pid_t(pidString), pid > 0 else { continue }
            let name = group(2) ?? "pid \(pid)"
            let kind = group(3) ?? ""
            guard SleepAssertion.awakeKinds.contains(kind) else { continue }
            let detail = group(4)

            let assertion = SleepAssertion(pid: pid, processName: name, kind: kind, detail: detail)
            if seen.insert(assertion.id).inserted {
                results.append(assertion)
            }
        }
        return results
    }
}
