// What a share card shows, decided without rendering anything.
//
// The card itself is a SwiftUI view in the app, which cannot be tested. This
// is the part that can be, and it is the part with the decisions in it: which
// apps make the cut, what a missing reading prints, and the fact that every
// figure on the card is the app's own `Fmt` output rather than a second set of
// formatting rules that could drift from the dashboard's.
import Foundation

/// One app's row on a share card.
public struct ShareCardAppEntry: Sendable, Equatable {
    public let name: String
    /// Already formatted by `Fmt.bytes`, so the card and the dashboard cannot
    /// disagree about what "8.2 GB" means.
    public let memory: String
    public let processCount: Int

    public init(name: String, memory: String, processCount: Int) {
        self.name = name
        self.memory = memory
        self.processCount = processCount
    }
}

/// Everything the share card renders, resolved and formatted.
///
/// Built from a snapshot so the card is a record of one moment rather than
/// something that keeps changing while the sheet is open.
public struct ShareCardContent: Sendable, Equatable {
    /// 1200×630 is the Open Graph size every social platform crops to, so the
    /// card survives being posted rather than only being read in a folder.
    public static let pixelWidth: CGFloat = 1200
    public static let pixelHeight: CGFloat = 630
    /// Rendered at 2× so the PNG is 2400×1260 — legible on a Retina display
    /// and not soft when a platform downscales it.
    public static let renderScale: CGFloat = 2

    /// Five rows plus a heading is what fits legibly at this height. Ten rows
    /// would each be unreadably small, which is the failure mode of a card
    /// that tries to show everything.
    public static let appRowLimit = 5

    public let machineName: String
    public let subtitle: String
    public let timestamp: Date
    /// Formatted by `Fmt.bytes` against the total, or nil when memory has
    /// never been read — nil renders as the same "—" the dashboard uses, not
    /// as a zero.
    public let memoryUsed: String?
    public let memoryTotal: String?
    public let cpu: String
    public let apps: [ShareCardAppEntry]

    /// The memory figure's caption, as a whole sentence.
    ///
    /// Assembled here rather than in the view because the grammar is part of
    /// the claim, not the layout: the view holds two bare byte strings and this
    /// decides how they read together. Concatenating "in memory" onto a caption
    /// that already said it produced "of 64.0 GB in memory in memory", which is
    /// what a render check caught.
    public var memoryCaption: String {
        guard let total = memoryTotal else { return "memory not read yet" }
        return "of \(total) in memory"
    }

    /// The CPU figure, or nil when the CPU has never been sampled.
    ///
    /// `SystemCPU` has no unknown representation for its percentage — `.unknown`
    /// reports `totalPercent: 0`, not nil — so a card that read the percentage
    /// directly would print "0.0%" for a machine it knows nothing about. The
    /// core count is the signal that actually distinguishes the two: a real
    /// sample always knows how many cores it measured across.
    public static func cpuPercent(from cpu: SystemCPU) -> Double? {
        cpu.coreCount > 0 ? cpu.totalPercent : nil
    }

    /// The snapshot this describes, as a short local-time stamp.
    ///
    /// A share card is a picture of one moment, and a card showing only a
    /// date would let someone post a two-week-old reading as current. The
    /// time is not decoration; it is the claim's scope.
    public var timestampText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return formatter.string(from: timestamp)
    }

    /// Whether the card is showing anything real at all.
    ///
    /// `distantPast` is the engine's "nothing sampled yet" sentinel. A card
    /// rendered from it would be a confident-looking picture of no data, so
    /// the export is refused instead.
    public var hasReading: Bool { timestamp != .distantPast }

    /// The top apps by memory, formatted.
    ///
    /// Ties are broken by name so the card is reproducible: two apps at
    /// exactly the same byte count would otherwise swap places between
    /// exports and make two identical cards look like different machines.
    /// Apps with no memory reading sort last rather than being dropped, so a
    /// machine where nothing has been read still shows what it knows.
    public static func topApps(
        from rollups: [AppRollup],
        limit: Int = appRowLimit
    ) -> [ShareCardAppEntry] {
        rollups
            .sorted { lhs, rhs in
                if lhs.totalMemory != rhs.totalMemory { return lhs.totalMemory > rhs.totalMemory }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .prefix(limit)
            .map { rollup in
                ShareCardAppEntry(
                    name: rollup.displayName,
                    memory: Fmt.bytes(rollup.totalMemory),
                    processCount: rollup.pidCount
                )
            }
    }

    /// Build the card from a live snapshot.
    ///
    /// `machineName` and `subtitle` are passed in rather than read here: the
    /// machine's name is a presentation concern that changes with the host,
    /// and reading it from Core would make this type untestable off-device.
    public static func make(
        snapshot: ObservationSnapshot,
        machineName: String,
        subtitle: String,
        limit: Int = appRowLimit
    ) -> ShareCardContent {
        ShareCardContent(
            machineName: machineName,
            subtitle: subtitle,
            timestamp: snapshot.at,
            memoryUsed: snapshot.system.memory.usedBytes > 0
                ? Fmt.bytes(snapshot.system.memory.usedBytes)
                : nil,
            memoryTotal: snapshot.system.memory.totalBytes > 0
                ? Fmt.bytes(snapshot.system.memory.totalBytes)
                : nil,
            cpu: Fmt.cpu(cpuPercent(from: snapshot.system.cpu)),
            apps: topApps(from: snapshot.rollups, limit: limit)
        )
    }
}
