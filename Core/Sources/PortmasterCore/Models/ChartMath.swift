// Chart math shared by the History UI and tests.
import Foundation

public enum ChartMath {
    public struct Point: Identifiable, Hashable, Sendable {
        public let at: Date
        public let value: Double
        public var id: Date { at }
        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    /// Bucket-average into at most maxPoints, preserving the newest timestamps.
    public static func downsample(_ points: [Point], maxPoints: Int) -> [Point] {
        guard points.count > maxPoints, maxPoints > 0 else { return points }
        let bucketSize = Double(points.count) / Double(maxPoints)
        var result: [Point] = []
        result.reserveCapacity(maxPoints)
        for bucket in 0..<maxPoints {
            let start = Int(Double(bucket) * bucketSize)
            let end = min(points.count, Int(Double(bucket + 1) * bucketSize))
            guard start < end else { continue }
            let slice = points[start..<end]
            let avg = slice.reduce(0.0) { $0 + $1.value } / Double(slice.count)
            result.append(Point(at: slice.last!.at, value: avg))
        }
        return result
    }
}
