// Every sentence Portmaster says about an app acting up.
//
// Six call sites used to write these by hand: four in `AlertEngine` for live
// readings and two in `OnDemandProvider` for the same observations
// reconstructed from recorded history. That meant a threshold change could
// leave one module describing a window the other no longer used — and nothing
// tested the wording, so a drift would have shipped silently.
//
// Everything window-shaped is derived from the threshold constants rather than
// written next to them, so the sentence and the number that triggered it
// cannot disagree. That rule is the same one `OnDemandProvider.spanDescription`
// already followed on its own.
import Foundation

public enum AlertCopy {
    /// Whether an observation is a reading or a reconstruction from history.
    ///
    /// Not decoration. A person or an MCP client reading an alert rebuilt from
    /// stored samples is being told something different from someone reading
    /// one the live engine has just raised, and Portmaster's premise is that it
    /// does not blur an observation's provenance.
    public enum Source: Sendable, Equatable {
        /// Measured now, by the running app.
        case live
        /// Reconstructed from recorded history — the observation is real, its
        /// freshness is not.
        case history

        /// The qualifier reconstructed observations carry, appended to a
        /// sentence that already ends in a full stop.
        ///
        /// The leading space is part of the qualifier rather than added at each
        /// call site, because a call site that forgot it would produce
        /// "minutes.From recorded history." — and a test comparing the live and
        /// history forms is what caught exactly that.
        var qualifier: String {
            switch self {
            case .live: ""
            case .history: " From recorded history."
            }
        }
    }

    // MARK: - Window wording

    /// How long a window reads as in a sentence: "10 minutes", "1 hour".
    ///
    /// Derived from the interval rather than written beside it, so a threshold
    /// change cannot leave a message describing a window that is no longer in
    /// use. Units are chosen only when the interval divides evenly, so a
    /// 90-minute window reads as "90 minutes" rather than rounding to a
    /// "1 hour" it never was.
    public static func spanDescription(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        func plural(_ count: Int, _ unit: String) -> String {
            "\(count) \(unit)\(count == 1 ? "" : "s")"
        }
        // Zero is not a window, and `0 % 60 == 0` would otherwise pick the
        // largest unit and read a sub-second interval as "0 hours". Seconds
        // are the honest floor: they are the only unit that cannot round away
        // the magnitude.
        if seconds == 0 { return plural(seconds, "second") }
        if seconds % 3600 == 0 { return plural(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return plural(seconds / 60, "minute") }
        return plural(seconds, "second")
    }

    // MARK: - Headlines

    /// The headlines name the app and the trend, because in Portmaster the
    /// headline *is* the card's heading — there is no separate title above it
    /// to carry the app name.
    public static func headline(_ kind: ActingUpAlert.Kind, appName: String) -> String {
        switch kind {
        case .sustainedCPU: "\(appName) is keeping the CPU busy"
        case .memoryGrowth: "\(appName) keeps using more memory"
        case .diskHammering: "\(appName) is hammering the disk"
        case .networkHammering: "\(appName) is using a lot of network"
        }
    }

    // MARK: - Details

    /// Sustained CPU: a whole-number average over the window.
    ///
    /// "on average for 10 minutes" rather than "average over the last 10
    /// minutes" — the same claim in fewer words.
    public static func sustainedCPU(_ percent: Double, source: Source) -> String {
        "\(Int(percent))% on average for \(spanDescription(AlertEngine.cpuWindow)).\(source.qualifier)"
    }

    /// Memory growth: what was gained, over what baseline, and where it stands.
    ///
    /// The window here is a baseline age, not a sliding average, so it reads
    /// "in the last hour" — "for an hour" would claim a duration of growth that
    /// the measurement does not establish.
    public static func memoryGrowth(
        growth: String,
        now: String,
        source: Source
    ) -> String {
        "Up \(growth) in the last \(spanDescription(AlertEngine.memGrowthWindow)), now \(now).\(source.qualifier)"
    }

    /// Disk writes, averaged over the hammering window.
    public static func diskHammering(_ rate: String, source: Source) -> String {
        "\(rate) written on average for \(spanDescription(AlertEngine.hammerWindow)).\(source.qualifier)"
    }

    /// Downloads, averaged over the hammering window.
    public static func networkHammering(_ rate: String, source: Source) -> String {
        "\(rate) downloaded on average for \(spanDescription(AlertEngine.hammerWindow)).\(source.qualifier)"
    }

    /// The whole observation: headline and detail for one kind.
    ///
    /// Assembled together so a caller cannot pair one kind's headline with
    /// another's detail — the failure mode of two independent lookups.
    public static func observation(
        _ kind: ActingUpAlert.Kind,
        appName: String,
        percent: Double? = nil,
        rate: String? = nil,
        growth: String? = nil,
        now: String? = nil,
        source: Source
    ) -> (headline: String, detail: String) {
        let detail: String
        switch kind {
        case .sustainedCPU:
            detail = sustainedCPU(percent ?? 0, source: source)
        case .memoryGrowth:
            detail = memoryGrowth(growth: growth ?? "—", now: now ?? "—", source: source)
        case .diskHammering:
            detail = diskHammering(rate ?? "—", source: source)
        case .networkHammering:
            detail = networkHammering(rate ?? "—", source: source)
        }
        return (headline(kind, appName: appName), detail)
    }
}
