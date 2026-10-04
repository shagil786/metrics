// SMCCollector: temperature and fan sensors via the AppleSMC user client
// using read-only commands. The
// key space is enumerated ONCE — model-independent, no per-chip key tables
// — and plausible keys are cached; each sample re-reads only those. The
// C surface lives in PMShim because the SMC structs need C layout.
//
// Byte-order note (verified on M4): the SMC returns 4-byte keys and type
// codes in the OPPOSITE order of the community's ASCII convention — the
// enum hands back e.g. "YEK#" for #KEY and " tlf" for 'flt '. Lookups
// therefore echo the raw bytes the enumeration produced; classification
// and decoding use the canonical (byte-reversed) forms.
import Foundation
import PMShim

/// One fan as the SMC reports it. Values the SMC did not return are nil.
public struct FanSample: Hashable, Sendable {
    /// SMC fan label, with a stable numbered fallback when no name is reported.
    public let name: String?
    public let currentRPM: Double?

    public init(name: String?, currentRPM: Double?) {
        self.name = name
        self.currentRPM = currentRPM
    }
}

/// What a thermal sample is a statement about. Three answers, kept apart because
/// "this machine has no sensors" and "no pass has finished yet" are different
/// facts: one is a property of the hardware, the other of the clock. Mirrors
/// `DockerAvailability` for the same reason.
public enum ThermalAvailability: Hashable, Sendable {
    /// A sensor pass ran and produced readings.
    case available
    /// A pass reached a readable SMC and no recognized sensor produced a
    /// plausible reading: no temperature/fan key of a type this collector
    /// decodes, or none of them decoded to a believable value. It is not a claim
    /// that the machine has no sensors — only that nothing this collector can
    /// read came back with a value.
    case noSensors
    /// No pass has observed anything: the SMC never opened, or not one cached
    /// key could be read. Says nothing at all about the machine's hardware.
    case notSampledYet
}

/// Machine thermal state. Every field is nil when its sensors are absent
/// (no keys for that group, SMC unavailable) — never zero-filled.
/// `availability` says which of the three answers the sample as a whole is, so
/// the readings are never read as the answer on their own: all-nil readings can
/// mean "nothing readable answered" or "nothing has been observed yet", and
/// only the enum tells those apart.
public struct ThermalSample: Hashable, Sendable {
    /// Which of the three answers this sample carries.
    public let availability: ThermalAvailability
    public let cpuTempC: Double?
    public let gpuTempC: Double?
    /// Hottest plausible sensor of any kind — the reference's "Hottest".
    public let hottestTempC: Double?
    public let fans: [FanSample]

    /// Internal, not public: `readings`, `noSensors` and `notSampledYet` are the
    /// only ways in, so a sample's state and the readings it carries cannot be
    /// assembled independently of each other. Requiring the argument only buys
    /// the naming — a public init would still accept `noSensors` beside a
    /// temperature.
    init(
        availability: ThermalAvailability, cpuTempC: Double?, gpuTempC: Double?,
        hottestTempC: Double?, fans: [FanSample]
    ) {
        self.availability = availability
        self.cpuTempC = cpuTempC
        self.gpuTempC = gpuTempC
        self.hottestTempC = hottestTempC
        self.fans = fans
    }

    /// Readings from a pass that observed them.
    public static func readings(
        cpuTempC: Double?, gpuTempC: Double?, hottestTempC: Double?, fans: [FanSample]
    ) -> ThermalSample {
        ThermalSample(
            availability: .available, cpuTempC: cpuTempC, gpuTempC: gpuTempC,
            hottestTempC: hottestTempC, fans: fans
        )
    }

    /// A readable key space with nothing plausible in it. Carries no readings,
    /// so it can never be read as a sensor reporting zero.
    public static let noSensors = ThermalSample(
        availability: .noSensors, cpuTempC: nil, gpuTempC: nil, hottestTempC: nil, fans: []
    )

    /// Nothing has been observed yet. The same readings as `noSensors`, and a
    /// different fact: no pass has read the machine, so this says nothing about
    /// its hardware.
    public static let notSampledYet = ThermalSample(
        availability: .notSampledYet, cpuTempC: nil, gpuTempC: nil, hottestTempC: nil, fans: []
    )
}

/// One sensor pass. Non-optional on purpose: every pass answers with the state
/// it established, so a caller cannot mistake "this pass found nothing" for
/// "no pass has run" — or, worse, for a fact about the machine's hardware.
public protocol ThermalProviding: Sendable {
    func sample() -> ThermalSample
}

public final class SMCCollector: ThermalProviding, @unchecked Sendable {
    /// A key as the SMC knows it: raw lookup bytes plus the canonical
    /// (byte-reversed) ASCII name used for classification.
    private struct SMCKey {
        let raw: [UInt8]
        let canonical: String
    }

    private var cpuKeys: [SMCKey] = []
    private var gpuKeys: [SMCKey] = []
    private var allTempKeys: [SMCKey] = []
    private var fanRpmKeys: [SMCKey] = []
    private var fanNames: [String: String] = [:]
    private var scanned = false
    /// Raw SMC reads that answered during the current pass. Zero means the
    /// machine said nothing at all, which is a different fact from "it said
    /// nothing plausible" — see `sample()`.
    private var rawReadsAnswered = 0
    // PMShim shares one connection across collector instances.
    private static let lock = NSLock()

    public init() {}

    /// Sample the cached sensors. The first call performs the full SMC key
    /// enumeration (~1-2k keys, a few hundred ms on the slow lane,
    /// once per launch); later calls re-read only the cached keys.
    ///
    /// Always answers with what the pass established, and never with more:
    ///
    /// - readings this pass decoded,
    /// - `.noSensors` when a readable SMC held no key this collector decodes, or
    ///   none of them decoded to a believable value,
    /// - `.notSampledYet` when the SMC never opened, or when not one cached key
    ///   could be read — a pass that reached nothing observed nothing, so it must
    ///   not report the machine as having no sensors.
    public func sample() -> ThermalSample {
        Self.lock.lock(); defer { Self.lock.unlock() }
        rawReadsAnswered = 0
        if !scanned {
            scanLocked()
            // `scanLocked` leaves `scanned` false when the SMC never opened: the
            // key space was never enumerated, so nothing is known about it.
            guard scanned else { return .notSampledYet }
        }

        guard !allTempKeys.isEmpty || !fanRpmKeys.isEmpty else { return .noSensors }

        func readTemp(_ key: SMCKey) -> Double? {
            guard let value = readKey(key) else { return nil }
            guard Self.isPlausibleTemp(value) else { return nil }
            return value
        }

        let values = allTempKeys.reduce(into: [String: Double]()) { values, key in
            if let value = readTemp(key) { values[key.canonical] = value }
        }
        let cpuValues = cpuKeys.compactMap { values[$0.canonical] }
        let gpuValues = gpuKeys.compactMap { values[$0.canonical] }
        let allValues = Array(values.values)

        var fans: [FanSample] = []
        for key in fanRpmKeys {
            guard let rpm = readKey(key), rpm >= 0, rpm < 30_000 else { continue }
            let number = Int(key.canonical.dropFirst().prefix(1)).map { $0 + 1 } ?? 1
            let name = fanNames[String(key.canonical.prefix(2))] ?? "Fan \(number)"
            fans.append(FanSample(name: name, currentRPM: rpm))
        }

        guard rawReadsAnswered > 0 else { return .notSampledYet }
        guard !allValues.isEmpty || !fans.isEmpty else { return .noSensors }
        return ThermalSample.readings(
            cpuTempC: cpuValues.max(),
            gpuTempC: gpuValues.max(),
            hottestTempC: allValues.max(),
            fans: fans
        )
    }

    // MARK: - Key-space enumeration

    /// Enumerate the whole SMC key space once and classify the
    /// temperature-type keys. Cache even temporarily invalid readings so
    /// a cold/idle sensor can recover. The first failed index ends the scan.
    ///
    /// `scanned` stays false when the SMC never opened or not one key could be
    /// enumerated, so the pass reports `notSampledYet` rather than an empty key
    /// space it never actually saw. Both are retried on the next pass.
    private func scanLocked() {
        guard pm_smc_open() else { return }
        var cpu: [SMCKey] = []
        var gpu: [SMCKey] = []
        var temps: [SMCKey] = []
        var rpmKeys: [SMCKey] = []
        var names: [String: String] = [:]
        var enumerated = 0

        for index in 0..<4000 {
            var raw4 = [CChar](repeating: 0, count: 4)
            guard pm_smc_key_at(UInt32(index), &raw4) == 1 else { break }
            enumerated += 1
            let raw = raw4.prefix(4).map { UInt8(bitPattern: $0) }
            guard let canonical = Self.canonicalString(raw), canonical.count == 4 else { continue }
            let key = SMCKey(raw: raw, canonical: canonical)

            if Self.isFanRpmKey(canonical) {
                rpmKeys.append(key)
                continue
            }
            if Self.isFanNameKey(canonical) {
                if let name = readFanName(key) { names[String(canonical.prefix(2))] = name }
                continue
            }
            // Everything else starting with T is a temperature candidate.
            guard canonical.hasPrefix("T") else { continue }
            guard let type = typeCode(key), type == "flt " || type == "sp78" else { continue }

            temps.append(key)
            if Self.isCpuTempKey(canonical) { cpu.append(key) }
            if Self.isGpuTempKey(canonical) { gpu.append(key) }
        }

        // Every Mac with a working SMC exposes thousands of keys, so an
        // enumeration that yielded none did not reach the key space at all.
        guard enumerated > 0 else { return }

        scanned = true
        cpuKeys = cpu
        gpuKeys = gpu
        allTempKeys = temps
        fanRpmKeys = rpmKeys
        fanNames = names
    }

    private func typeCode(_ key: SMCKey) -> String? {
        var type4 = [CChar](repeating: 0, count: 4)
        guard pm_smc_read_type(key.raw, &type4) == 1 else { return nil }
        return Self.canonicalString(type4.map { UInt8(bitPattern: $0) })
    }

    /// Read one key and decode by its type. nil when absent or undecodable.
    private func readKey(_ key: SMCKey) -> Double? {
        guard let type = typeCode(key) else { return nil }
        var raw = [UInt8](repeating: 0, count: 32)
        let size = pm_smc_read(key.raw, &raw, 32)
        guard size > 0 else { return nil }
        // The SMC answered for this key. Counted whether or not the payload
        // decodes: an implausible value is the sensor speaking, while a failed
        // read is the machine not answering at all.
        rawReadsAnswered += 1
        return Self.decode(type: type, bytes: Array(raw.prefix(Int(size))))
    }

    /// Fan label from an F<n>Nm key: type `ch8*`, NUL-padded ASCII.
    private func readFanName(_ key: SMCKey) -> String? {
        var raw = [UInt8](repeating: 0, count: 32)
        let size = pm_smc_read(key.raw, &raw, 32)
        guard size > 0 else { return nil }
        let text = raw.prefix(Int(size)).prefix { $0 != 0 }
        guard let s = String(bytes: text, encoding: .ascii)?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Pure classification & decoding (unit-tested)

    /// Canonical ASCII name: the SMC hands keys back byte-reversed.
    static func canonicalString(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 4 else { return nil }
        let reversed = bytes.reversed()
        guard reversed.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        return String(bytes: reversed, encoding: .ascii)
    }

    /// "F0Ac"-style fan current-RPM key.
    static func isFanRpmKey(_ key: String) -> Bool {
        let chars = Array(key)
        return chars.count == 4 && chars[0] == "F" && chars[1].isNumber
            && chars[2] == "A" && chars[3] == "c"
    }

    /// "F0Nm"-style fan name key.
    static func isFanNameKey(_ key: String) -> Bool {
        let chars = Array(key)
        return chars.count == 4 && chars[0] == "F" && chars[1].isNumber
            && chars[2] == "N" && chars[3] == "m"
    }

    /// CPU temperature keys: Tp*/TPD* (Apple Silicon P-core clusters) and
    /// TC* (Intel package/core proximity), excluding TCM* memory sensors.
    static func isCpuTempKey(_ key: String) -> Bool {
        key.hasPrefix("Tp") || key.hasPrefix("TP")
            || (key.hasPrefix("TC") && !key.hasPrefix("TCM"))
    }

    /// GPU temperature keys: Tg*/TG*.
    static func isGpuTempKey(_ key: String) -> Bool {
        key.hasPrefix("Tg") || key.hasPrefix("TG")
    }

    /// Zone and idle sensors read 0.0 or wild values; only accept a
    /// physically believable range so averages and "Hottest" stay honest.
    static func isPlausibleTemp(_ value: Double) -> Bool {
        value >= 5 && value <= 150
    }

    /// Decode an SMC value by its canonical 4-char type code. Covers the
    /// types that occur for temperature/fan keys: 'flt ' (32-bit float —
    /// little-endian payload, used on Apple Silicon for temps and fan RPM), 'sp78' (signed 7.8
    /// fixed — Intel temps), 'fpe2' (unsigned big-endian, legacy fan RPM),
    /// 'ui8'/'ui32'/'si32'.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: be16(0))) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(be16(0)) / 4.0
        case "ui8 ":
            guard !bytes.isEmpty else { return nil }
            return Double(bytes[0])
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(be32(0))
        case "si32":
            guard bytes.count >= 4 else { return nil }
            return Double(Int32(bitPattern: be32(0)))
        default:
            return nil
        }
    }
}
