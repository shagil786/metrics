// AlertEngine: "acting up" detection in the vitalsmac model — plain-language
// observations about apps, with cooldowns and local-only delivery.
// Sustained CPU, memory growth, and disk/network hammering: the disk and
// network signals come from per-process rusage counters and nettop, both
// supported APIs — rates feed the same full-window discipline as CPU.
import Foundation
import UserNotifications

public struct ActingUpAlert: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case sustainedCPU
        case memoryGrowth
        case diskHammering
        case networkHammering
    }

    public let id: String
    public let kind: Kind
    public let appName: String
    /// Headline, e.g. "Chrome is keeping the CPU busy".
    public let headline: String
    /// Detail, e.g. "70% average over 10 minutes."
    public let detail: String
    public let at: Date

    public init(id: String, kind: Kind, appName: String, headline: String, detail: String, at: Date) {
        self.id = id
        self.kind = kind
        self.appName = appName
        self.headline = headline
        self.detail = detail
        self.at = at
    }
}

public final class AlertEngine: @unchecked Sendable {
    // Thresholds (documented in Settings copy).
    public static let cpuWindow: TimeInterval = 600        // 10 minutes
    public static let cpuThreshold: Double = 50            // percent, avg over window
    public static let memGrowthWindow: TimeInterval = 3600 // 1 hour
    public static let memGrowthBytes: UInt64 = 1_073_741_824 // 1 GiB in window
    /// Hammering = a sustained RATE, not a spike: the average must hold over
    /// the full window before an alert may fire.
    public static let hammerWindow: TimeInterval = 600                // 10 minutes
    public static let diskHammerBytesPerSec: Double = 50 * 1_048_576    // 50 MB/s
    public static let networkHammerBytesPerSec: Double = 10 * 1_048_576 // 10 MB/s

    /// Deliver + record at most one alert per app+kind per hour.
    public static let cooldown: TimeInterval = 3600

    private var cpuRing: [String: RingBuffer] = [:]
    private var diskRing: [String: RingBuffer] = [:]
    private var netRing: [String: RingBuffer] = [:]
    private var memBaseline: [String: (at: Date, bytes: UInt64)] = [:]
    private var lastFired: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    struct RingBuffer {
        var points: [(at: Date, value: Double)] = []
        let capacity: Int

        mutating func append(_ at: Date, _ value: Double) {
            points.append((at, value))
            while !points.isEmpty, points[0].at.timeIntervalSinceNow < -Self.horizon {
                points.removeFirst()
            }
        }

        static let horizon: TimeInterval = cpuWindow + 60
    }

    /// Feed one sweep's rollups. Returns alerts that fired this tick.
    @discardableResult
    public func ingest(rollups: [AppRollup], at: Date, notify: Bool) -> [ActingUpAlert] {
        lock.lock()
        defer { lock.unlock() }

        var fired: [ActingUpAlert] = []

        for app in rollups where app.totalCPU > 1 || app.totalMemory > 128 * 1024 * 1024 {
            // --- Sustained CPU ---
            var ring = cpuRing[app.id] ?? RingBuffer(capacity: 600)
            ring.append(at, app.totalCPU)
            cpuRing[app.id] = ring

            let windowPoints = ring.points.filter { at.timeIntervalSince($0.at) <= Self.cpuWindow }
            // The window must be genuinely full ("50% average for 10 minutes"),
            // not a short spike averaged over partial data. 30s grace for
            // sampling interval alignment.
            if windowPoints.count >= 3,
               let oldest = windowPoints.first,
               at.timeIntervalSince(oldest.at) >= Self.cpuWindow - 30 {
                let avg = windowPoints.reduce(0.0) { $0 + $1.value } / Double(windowPoints.count)
                if avg >= Self.cpuThreshold, readyToFire(key: app.id + ":cpu", now: at) {
                    fired.append(ActingUpAlert(
                        id: app.id + ":cpu:" + ISO8601DateFormatter().string(from: at),
                        kind: .sustainedCPU,
                        appName: app.displayName,
                        headline: AlertCopy.headline(.sustainedCPU, appName: app.displayName),
                        detail: AlertCopy.sustainedCPU(avg, source: .live),
                        at: at
                    ))
                }
            }

            // --- Memory growth ---
            if let base = memBaseline[app.id] {
                let inWindow = at.timeIntervalSince(base.at) <= Self.memGrowthWindow
                let growth = app.totalMemory >= base.bytes
                    ? app.totalMemory - base.bytes
                    : 0
                if inWindow, growth >= Self.memGrowthBytes, readyToFire(key: app.id + ":mem", now: at) {
                    fired.append(ActingUpAlert(
                        id: app.id + ":mem:" + ISO8601DateFormatter().string(from: at),
                        kind: .memoryGrowth,
                        appName: app.displayName,
                        headline: AlertCopy.headline(.memoryGrowth, appName: app.displayName),
                        detail: AlertCopy.memoryGrowth(
                            growth: Fmt.bytes(growth),
                            now: Fmt.bytes(app.totalMemory),
                            source: .live
                        ),
                        at: at
                    ))
                }
                if !inWindow {
                    memBaseline[app.id] = (at, app.totalMemory)
                } else if app.totalMemory < base.bytes {
                    // Freed memory: reset baseline so the next climb measures from here.
                    memBaseline[app.id] = (at, app.totalMemory)
                }
            } else {
                memBaseline[app.id] = (at, app.totalMemory)
            }

            // --- Disk hammering (per-process rusage write rates) ---
            // nil = not yet measurable (first sweeps / partial coverage);
            // a nil never enters the ring, so averages stay honest.
            if let writeRate = app.totalDiskWriteBytesPerSec {
                var ring = diskRing[app.id] ?? RingBuffer(capacity: 600)
                ring.append(at, writeRate)
                diskRing[app.id] = ring

                let points = ring.points.filter { at.timeIntervalSince($0.at) <= Self.hammerWindow }
                if points.count >= 3,
                   let oldest = points.first,
                   at.timeIntervalSince(oldest.at) >= Self.hammerWindow - 30 {
                    let avg = points.reduce(0.0) { $0 + $1.value } / Double(points.count)
                    if avg >= Self.diskHammerBytesPerSec, readyToFire(key: app.id + ":disk", now: at) {
                        fired.append(ActingUpAlert(
                            id: app.id + ":disk:" + ISO8601DateFormatter().string(from: at),
                            kind: .diskHammering,
                            appName: app.displayName,
                            headline: AlertCopy.headline(.diskHammering, appName: app.displayName),
                            detail: AlertCopy.diskHammering(Fmt.rate(avg), source: .live),
                            at: at
                        ))
                    }
                }
            }

            // --- Network hammering (nettop download rates) ---
            if let netRate = app.totalNetInBytesPerSec {
                var ring = netRing[app.id] ?? RingBuffer(capacity: 600)
                ring.append(at, netRate)
                netRing[app.id] = ring

                let points = ring.points.filter { at.timeIntervalSince($0.at) <= Self.hammerWindow }
                if points.count >= 3,
                   let oldest = points.first,
                   at.timeIntervalSince(oldest.at) >= Self.hammerWindow - 30 {
                    let avg = points.reduce(0.0) { $0 + $1.value } / Double(points.count)
                    if avg >= Self.networkHammerBytesPerSec, readyToFire(key: app.id + ":net", now: at) {
                        fired.append(ActingUpAlert(
                            id: app.id + ":net:" + ISO8601DateFormatter().string(from: at),
                            kind: .networkHammering,
                            appName: app.displayName,
                            headline: AlertCopy.headline(.networkHammering, appName: app.displayName),
                            detail: AlertCopy.networkHammering(Fmt.rate(avg), source: .live),
                            at: at
                        ))
                    }
                }
            }
        }

        for alert in fired where notify {
            deliver(alert)
        }
        return fired
    }

    private func readyToFire(key: String, now: Date) -> Bool {
        if let last = lastFired[key], now.timeIntervalSince(last) < Self.cooldown {
            return false
        }
        lastFired[key] = now
        return true
    }

    // MARK: - Delivery

    private func deliver(_ alert: ActingUpAlert) {
        // UNUserNotificationCenter requires a real app bundle; unit tests and
        // CLIs must not crash when ingest(notify: true) runs.
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Portmaster"
        content.body = "\(alert.headline) — \(alert.detail)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: alert.id,
            content: content,
            trigger: nil // immediate; dedup by identifier
        )
        center.add(request)
    }

    /// Recent alerts for the Alerts tab (kept by the app layer).
    public static func requestAuthorizationIfNeeded() async -> Bool {
        // Outside a real app bundle (unit tests, CLI) there is no notification
        // center; report not-authorized rather than crashing.
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}
