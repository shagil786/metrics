// Windowed CPU statistics derived from persisted HistoryStore samples:
// a since-midnight average for the CPU tab hero ("Average today") and the
// mean-CPU chart series for the hero's area chart. Only stored samples are
// used — the average is honest "—" until the second sample exists.
import Foundation

public struct CpuWindowStats: Sendable, Hashable {
    /// Mean of persisted CPU samples since midnight. nil with fewer than 2
    /// samples — a single sample is not an average.
    public let averageTodayPercent: Double?
    /// Series of window-mean CPU values (equal-count buckets across the day's
    /// samples), one per element, for the hero chart's dashed average line.
    public let averageSeries: [Double]
    public let sampleCount: Int

    public init(averageTodayPercent: Double?, averageSeries: [Double], sampleCount: Int) {
        self.averageTodayPercent = averageTodayPercent
        self.averageSeries = averageSeries
        self.sampleCount = sampleCount
    }

    /// Pure aggregation over (value, date) pairs so tests need no SwiftData.
    public static func compute(
        samples: [(value: Double, at: Date)],
        now: Date = Date(),
        buckets: Int = 48
    ) -> CpuWindowStats {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let todays = samples.filter { $0.at >= dayStart && $0.at <= now }
        guard todays.count >= 2 else {
            return CpuWindowStats(averageTodayPercent: nil, averageSeries: [], sampleCount: todays.count)
        }

        // Equal-count buckets across today's samples: each bucket is the mean
        // of an equal slice of the day's observations, so sparse periods don't
        // dominate the shape and busy periods aren't washed out.
        let n = todays.count
        let bounded = max(2, min(buckets, n))
        var series: [Double] = []
        series.reserveCapacity(bounded)
        let width = Double(n) / Double(bounded)
        for b in 0..<bounded {
            let lo = Int(Double(b) * width)
            let hi = min(n, Int(Double(b + 1) * width))
            let slice = todays[lo..<max(lo + 1, hi)]
            let mean = slice.reduce(0.0) { $0 + $1.value } / Double(slice.count)
            series.append(mean)
        }

        let avg = todays.reduce(0.0) { $0 + $1.value } / Double(n)
        return CpuWindowStats(averageTodayPercent: avg, averageSeries: series, sampleCount: n)
    }
}

public extension SystemInfo {
    /// P/E split for Apple Silicon via hw.perflevel*.logicalcpu sysctls.
    /// (perflevel0 = performance, perflevel1 = efficiency.) Both nil on
    /// machines the kernel doesn't describe this way — callers render an
    /// honest fallback, never a fabricated split.
    static func performanceCoreCounts() -> (performance: Int?, efficiency: Int?) {
        func count(_ level: Int32) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let name = "hw.perflevel\(level).logicalcpu"
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size, value > 0
            else { return nil }
            return Int(value)
        }
        let p = count(0)
        let e = count(1)
        // Guard against a kernel that reports only one bucket: a split needs
        // both sides to be meaningful.
        return (p != nil && e != nil) ? (p, e) : (nil, nil)
    }
}
