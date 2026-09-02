// CoolingHistory.swift — the on-disk envelope for cooling records: schema, machine identity, retention.

import CommonCrypto
import Foundation

/// Which machine a history file belongs to.
///
/// `R` is explicitly not comparable between machines, so a history that
/// followed `~/Library` through Migration Assistant onto a new Mac would
/// produce exactly the catastrophic false claim — "your cooling is 30 %
/// worse" about a machine that changed, not degraded. Decode refuses to
/// merge across machines, ever.
///
/// The serial travels only as a **salted hash**: enough to notice a
/// same-model restore (a warranty replacement is precisely the Mac most
/// likely to inherit a degraded baseline), while the file itself holds no
/// identifier. `fanMaxRPM` is stored for re-interpretation but deliberately
/// **not matched**: `F{i}Mn`/`F{i}Mx` are read with independent per-key
/// fallbacks that can glitch for a launch, and one bad read must not
/// quarantine a year of history — the serial hash is the strong
/// discriminator.
public struct MachineFingerprint: Sendable, Codable, Equatable {
    public let modelIdentifier: String
    public let fanCount: Int
    public let fanMaxRPM: [Int]
    public let isSimulated: Bool
    public let serialSalt: String?
    public let serialHash: String?

    public init(
        modelIdentifier: String,
        fanCount: Int,
        fanMaxRPM: [Int],
        isSimulated: Bool,
        serialNumber: String?,
        salt: String? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.fanCount = fanCount
        self.fanMaxRPM = fanMaxRPM
        self.isSimulated = isSimulated
        if let serialNumber {
            let salt = salt ?? Self.randomSalt()
            serialSalt = salt
            serialHash = Self.hash(serialNumber: serialNumber, salt: salt)
        } else {
            serialSalt = nil
            serialHash = nil
        }
    }

    /// Whether a file bearing this fingerprint belongs to the machine
    /// described by the arguments.
    ///
    /// The serial check is deliberately asymmetric: a stored hash is only
    /// enforced when the current serial could actually be read. An IOKit
    /// read that fails for one launch must degrade to "same machine", not
    /// destroy the history it was meant to protect.
    ///
    /// `fanCount` and `fanMaxRPM` are stored but **not matched**, for the
    /// same fragility reason as each other: the model identifier already
    /// implies the fan configuration, the fans are only known once a
    /// snapshot exists (not at load time), and a per-key `Mn`/`Mx` read
    /// glitch must not quarantine a year of history. The serial hash is the
    /// strong discriminator.
    public func matches(
        modelIdentifier: String,
        isSimulated: Bool,
        serialNumber: String?
    ) -> Bool {
        guard self.modelIdentifier == modelIdentifier,
              self.isSimulated == isSimulated
        else { return false }
        guard let serialSalt, let serialHash, let serialNumber else { return true }
        return Self.hash(serialNumber: serialNumber, salt: serialSalt) == serialHash
    }

    /// SHA-256 of `salt + serial`, hex. Honesty note for the docs: a serial
    /// number is low-entropy, so this prevents *accidental* reuse and casual
    /// reading, not a determined brute force — the file's privacy claim is
    /// "holds no identifier", not "cryptographically unlinkable".
    public static func hash(serialNumber: String, salt: String) -> String {
        let input = Data((salt + serialNumber).utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        input.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(input.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 16 random bytes, hex. A parameter on `init` so tests stay
    /// deterministic; random only when the caller does not care.
    public static func randomSalt() -> String {
        (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

/// Everything the cooling-history file holds, plus the retention rules that
/// bound it forever.
public struct CoolingHistory: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    // MARK: - Retention constants, and why each has its value

    /// Raw records live in the youngest seven UTC day-buckets, today
    /// included. Raw has three readers: the day aggregates, the jump detector
    /// (which needs sub-day resolution), and ``CoolingLaw/fit(_:)``, which fits
    /// its per-band lines through raw records — so the fitted law describes
    /// only the last week, which is the window a forecast wants.
    ///
    /// Pruning is **whole days only**, never by timestamp: a day whose raw
    /// has been partially pruned would re-fold to an aggregate built from
    /// less evidence than the one it overwrites — the outlier test caught
    /// precisely that, a complete day degrading record by record until its
    /// stored median *was* the one 1.89 transient.
    public static let rawRetentionDays = 7
    /// Exactly `7 × 288`: what seven day-buckets at the recorder's minimum
    /// spacing can produce, so the count cap and the day window say the same
    /// thing and neither can silently truncate the other. A test asserts the
    /// day window always bites first.
    public static let maximumRawRecords = 2016
    /// ~2 years at 5.5 bands/day. Set high enough that the cap can never
    /// evict the ≤ 365-day baseline horizon on a heavy multi-band machine —
    /// the trend's main-actor evaluation also depends on this staying small.
    public static let maximumDayAggregates = 4000
    /// Two years. Beyond that the machine is not the same experiment: a
    /// different OS fan policy, a different desk, a second display on the
    /// same power denominator.
    public static let maximumDayAgeDays = 730
    /// An unsynced clock at boot writes records dated 2030; a future-dated
    /// record poisons "recent" forever, so anything past this skew is
    /// dropped at compaction.
    public static let maximumFutureSkew: TimeInterval = 3600
    /// If the aggregate cap ever binds, thinning starts *after* the oldest
    /// 90 days: a history that evicts its own baseline first has thrown
    /// away the only thing it was for.
    public static let protectedOldestDays = 90

    // MARK: - Contents

    public let schemaVersion: Int
    public let machine: MachineFingerprint
    public let createdAt: Date
    /// Raw settled readings, ascending by date. Bounded by ``rawRetentionDays``
    /// — the whole-day window that in practice always bites first — with
    /// ``maximumRawRecords`` behind it as a count backstop.
    public private(set) var records: [CoolingRecord]
    /// Folded day-band aggregates, ascending by (day, band). Bounded by
    /// ``maximumDayAgeDays`` and ``maximumDayAggregates``.
    public private(set) var days: [CoolingDayAggregate]
    /// "I cleaned it" boundaries. The trend's baseline never spans one, so
    /// a repaste does not read as `improved` forever.
    public private(set) var serviceMarks: [Date]

    /// A fresh, empty history for this machine.
    public init(machine: MachineFingerprint, createdAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.machine = machine
        self.createdAt = createdAt
        records = []
        days = []
        serviceMarks = []
    }

    // MARK: - Mutation

    /// Appends one reading and immediately re-establishes every retention
    /// invariant. Called at most once per recorder spacing (~5 min), so
    /// compacting inline costs nothing and means there is no state in which
    /// the bounds do not hold.
    public mutating func append(_ record: CoolingRecord, now: Date) {
        records.append(record)
        compact(now: now)
    }

    /// Records that the machine was physically serviced — cleaned, repasted, a fan
    /// replaced — on `date`.
    ///
    /// A boundary, not an annotation: ``CoolingTrend`` never lets a baseline span
    /// one, so a repaste stops reading as `improved` forever and the comparison
    /// restarts from the machine as it now is. Marks are kept sorted, and the trend
    /// filters to `<= now` before using them, so a mark dated in the future by an
    /// unsynced clock cannot silently truncate every baseline.
    public mutating func markServiced(at date: Date) {
        serviceMarks.append(date)
        serviceMarks.sort()
    }

    /// Folds complete days into aggregates and prunes both tiers. Idempotent:
    /// running it twice at the same `now` is byte-identical, and folding is
    /// keyed by (day, band) with overwrite, so a day is never counted twice.
    public mutating func compact(now: Date) {
        let today = CoolingStatistics.dayIndex(now)

        // 1. A record from the future would poison "recent" forever.
        records.removeAll { $0.date > now + Self.maximumFutureSkew }
        records.sort { $0.date < $1.date }

        // 2. Fold complete days only — today is still happening — and only
        //    days newer than the newest stored aggregate. A folded day's raw
        //    can never change afterwards (appends arrive at "now", and
        //    pruning is whole-day), so re-folding it is always a no-op; and
        //    for any day whose raw still exists the trend folds live anyway,
        //    so the stored value only ever matters after the prune.
        let maxStoredDay = days.last?.day ?? Int.min
        let complete = records.filter { $0.day < today && $0.day > maxStoredDay }
        if !complete.isEmpty {
            var byKey = Dictionary(
                uniqueKeysWithValues: days.map { (DayBandKey(day: $0.day, band: $0.band), $0) }
            )
            for aggregate in CoolingDayAggregate.fold(complete) {
                byKey[DayBandKey(day: aggregate.day, band: aggregate.band)] = aggregate
            }
            days = byKey.values.sorted { ($0.day, $0.band.sortKey) < ($1.day, $1.band.sortKey) }
        }

        // 3. Prune raw by whole day-buckets — fold (step 2) always ran
        //    first within this call, so nothing is ever pruned unfolded,
        //    and a retained day always has ALL its records. The count cap
        //    is a backstop the day window should always beat.
        let rawCutoffDay = today - (Self.rawRetentionDays - 1)
        records.removeAll { $0.day < rawCutoffDay }
        if records.count > Self.maximumRawRecords {
            records.removeFirst(records.count - Self.maximumRawRecords)
        }

        // 4. Prune aggregates by age, then thin over the count cap — never
        //    from the protected oldest days (see `protectedOldestDays`).
        days.removeAll { $0.day < today - Self.maximumDayAgeDays }
        while days.count > Self.maximumDayAggregates {
            let protectedCutoff = (days.first?.day ?? today) + Self.protectedOldestDays
            let victim = days.firstIndex { $0.day > protectedCutoff } ?? days.count / 2
            days.remove(at: victim)
        }
    }

    private struct DayBandKey: Hashable {
        let day: Int
        let band: FanBand
    }

    // MARK: - Coding (pure — the store owns the filesystem)

    /// What loading a history file can honestly result in.
    public enum LoadOutcome: Sendable, Equatable {
        case loaded(CoolingHistory)
        /// Quarantine the file and begin again.
        case startFresh(Reason)
        /// Do **not** write this launch. The file is newer than this build
        /// understands; overwriting would destroy months of history to save
        /// one launch of recording. Losing a launch is cheap; losing a year
        /// is not.
        case readOnly(Reason)

        /// Why a history file could not simply be loaded.
        ///
        /// Three causes with three different costs, which is why they are not one
        /// Bool: the first two quarantine and begin again, while `schemaTooNew` must
        /// **not** write this launch — overwriting would destroy months of history
        /// to save one launch of recording.
        public enum Reason: Sendable, Equatable {
            /// The JSON did not decode at all.
            case unreadable
            /// The fingerprint names a different Mac. `R` is not comparable between
            /// machines, so the readings answer no question this file exists for.
            case machineChanged
            /// The file's `schemaVersion`, which this build has never heard of.
            case schemaTooNew(Int)
        }
    }

    /// Decodes a history file for the machine described by the arguments.
    ///
    /// Forward-compat contract, stated here because decode is where it
    /// bites: **every field added after v1 must be `Optional` with a
    /// default**, so a newer file still decodes on an older build (the
    /// `SMCSnapshot.power` precedent). A version this build has never heard
    /// of is `readOnly`, not quarantined — the newer build's data survives a
    /// temporary downgrade untouched.
    public static func decode(
        _ data: Data,
        modelIdentifier: String,
        isSimulated: Bool,
        serialNumber: String?
    ) -> LoadOutcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            return .startFresh(.unreadable)
        }
        guard probe.schemaVersion <= currentSchemaVersion else {
            return .readOnly(.schemaTooNew(probe.schemaVersion))
        }
        guard var history = try? decoder.decode(CoolingHistory.self, from: data) else {
            return .startFresh(.unreadable)
        }
        guard history.machine.matches(
            modelIdentifier: modelIdentifier,
            isSimulated: isSimulated,
            serialNumber: serialNumber
        ) else {
            return .startFresh(.machineChanged)
        }
        history.records.sort { $0.date < $1.date }
        return .loaded(history)
    }

    /// Encodes for disk: sorted keys and pretty-printed, because this file
    /// is what a user will be asked to look at when they dispute a verdict,
    /// and the repo's culture is that such artefacts are readable.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }
}
