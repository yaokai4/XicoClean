import CoreFoundation
import Foundation
import Domain

public enum HistoryOutcomeStatus: String, Codable, Equatable, Sendable {
    case success
    case partial
    case failure
    case cancelled
    case legacyUnknown

    init(_ status: OperationTerminalStatus) {
        switch status {
        case .success: self = .success
        case .partial: self = .partial
        case .failure: self = .failure
        case .cancelled: self = .cancelled
        }
    }
}

enum HistoryArchiveState: Equatable, Sendable {
    case writable
    case degradedReadOnly(code: String)
}

enum HistoryArchiveLimits {
    static let maximumArchiveBytes = 1_048_576
    static let maximumRecords = 500
    static let maximumItemFactsPerRecord = 256
    static let maximumIssuesPerOperation = 128
    static let maximumModuleUTF8Bytes = 256
    static let maximumKindUTF8Bytes = 256
    static let maximumCodeUTF8Bytes = 256
    static let maximumSubjectUTF8Bytes = 36
}

public struct HistoryItemFact: Sendable, Equatable {
    public let requestID: UUID
    public let intent: DeleteIntent
    public let disposition: OperationDisposition
    public let mutation: OperationMutationFact
    public let affectedBytes: Int64
    public let receipt: RestorableItem?

    init(
        requestID: UUID,
        intent: DeleteIntent,
        disposition: OperationDisposition,
        mutation: OperationMutationFact,
        affectedBytes: Int64,
        receipt: RestorableItem?
    ) {
        self.requestID = requestID
        self.intent = intent
        self.disposition = disposition
        self.mutation = mutation
        self.affectedBytes = affectedBytes
        self.receipt = receipt
    }

    func retainingReceipt(in allowed: Set<HistoryReceiptIdentity>) -> HistoryItemFact {
        guard let receipt,
              !allowed.contains(HistoryReceiptIdentity(receipt)) else { return self }
        return HistoryItemFact(
            requestID: requestID,
            intent: intent,
            disposition: disposition,
            mutation: mutation,
            affectedBytes: affectedBytes,
            receipt: nil)
    }
}

public struct CleaningRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let module: String
    public let reclaimedBytes: Int64
    public let removedCount: Int
    public let restorable: [RestorableItem]
    public let schemaVersion: Int
    public let operationID: UUID?
    public let parentOperationID: UUID?
    public let operationKind: OperationKind?
    public let outcomeStatus: HistoryOutcomeStatus
    public let mutation: OperationMutationFact?
    public let counts: OperationCounts?
    public let itemFacts: [HistoryItemFact]

    let startedAt: Date?
    let finishedAt: Date?
    let issues: [OperationIssue]
    let isTrustedForAggregates: Bool

    init(
        id: UUID,
        date: Date,
        module: String,
        reclaimedBytes: Int64,
        removedCount: Int,
        restorable: [RestorableItem],
        schemaVersion: Int,
        operationID: UUID?,
        parentOperationID: UUID?,
        operationKind: OperationKind?,
        outcomeStatus: HistoryOutcomeStatus,
        mutation: OperationMutationFact?,
        counts: OperationCounts?,
        itemFacts: [HistoryItemFact],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        issues: [OperationIssue] = [],
        isTrustedForAggregates: Bool = true
    ) {
        self.id = id
        self.date = date
        self.module = module
        self.reclaimedBytes = reclaimedBytes
        self.removedCount = removedCount
        self.restorable = restorable
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.parentOperationID = parentOperationID
        self.operationKind = operationKind
        self.outcomeStatus = outcomeStatus
        self.mutation = mutation
        self.counts = counts
        self.itemFacts = itemFacts
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.issues = issues
        self.isTrustedForAggregates = isTrustedForAggregates
    }

    public var canUndo: Bool { !restorable.isEmpty }

    func updatingRestorable(_ receipts: [RestorableItem]) -> CleaningRecord {
        let updatedFacts: [HistoryItemFact]
        let updatedRestorable: [RestorableItem]
        if schemaVersion == 1 {
            let allowed = Set(receipts.map(HistoryReceiptIdentity.init))
            updatedFacts = itemFacts.map { $0.retainingReceipt(in: allowed) }
            updatedRestorable = updatedFacts.compactMap(\.receipt)
        } else {
            updatedFacts = itemFacts
            let allowed = Set(receipts.map(HistoryReceiptIdentity.init))
            updatedRestorable = restorable.filter {
                allowed.contains(HistoryReceiptIdentity($0))
            }
        }
        return CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: reclaimedBytes,
            removedCount: removedCount,
            restorable: updatedRestorable,
            schemaVersion: schemaVersion,
            operationID: operationID,
            parentOperationID: parentOperationID,
            operationKind: operationKind,
            outcomeStatus: outcomeStatus,
            mutation: mutation,
            counts: counts,
            itemFacts: updatedFacts,
            startedAt: startedAt,
            finishedAt: finishedAt,
            issues: issues,
            isTrustedForAggregates: isTrustedForAggregates)
    }

    func hasSameImmutableOperationFacts(as other: CleaningRecord) -> Bool {
        schemaVersion == other.schemaVersion
            && module == other.module
            && reclaimedBytes == other.reclaimedBytes
            && removedCount == other.removedCount
            && operationID == other.operationID
            && parentOperationID == other.parentOperationID
            && operationKind == other.operationKind
            && outcomeStatus == other.outcomeStatus
            && mutation == other.mutation
            && counts == other.counts
            && itemFacts == other.itemFacts
            && startedAt == other.startedAt
            && finishedAt == other.finishedAt
            && issues == other.issues
    }

    func untrustedDuplicateConflictCopy() -> CleaningRecord {
        CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: 0,
            removedCount: 0,
            restorable: [],
            schemaVersion: schemaVersion,
            operationID: operationID,
            parentOperationID: parentOperationID,
            operationKind: operationKind,
            outcomeStatus: .legacyUnknown,
            mutation: mutation,
            counts: counts,
            itemFacts: itemFacts,
            startedAt: startedAt,
            finishedAt: finishedAt,
            issues: issues,
            isTrustedForAggregates: false)
    }

    func untrustedFutureDataCopy() -> CleaningRecord {
        CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: reclaimedBytes,
            removedCount: removedCount,
            restorable: restorable,
            schemaVersion: schemaVersion,
            operationID: operationID,
            parentOperationID: parentOperationID,
            operationKind: operationKind,
            outcomeStatus: outcomeStatus,
            mutation: mutation,
            counts: counts,
            itemFacts: itemFacts,
            startedAt: startedAt,
            finishedAt: finishedAt,
            issues: issues,
            isTrustedForAggregates: false)
    }
}

public enum HistoryRecordResult: Equatable, Sendable {
    case inserted(recordID: UUID)
    case alreadyRecorded(recordID: UUID)
    case notRecordedNoChanges
    case rejected(code: String)
}

public enum HistoryUpdateResult: Equatable, Sendable {
    case committed
    case notFound
    case rejected(code: String)
}

public protocol OutcomeHistoryWriting: Sendable {
    func record(
        module: String,
        report: CleaningReport,
        date: Date
    ) -> HistoryRecordResult
    func record(
        module: String,
        result: OperationResult<ShredderPayload>,
        date: Date
    ) -> HistoryRecordResult
    func remove(id: UUID) -> HistoryUpdateResult
    func updateRestorable(id: UUID, to: [RestorableItem]) -> HistoryUpdateResult
}

public enum HistoryReloadResult: Equatable, Sendable {
    case writable
    case degraded(code: String)
}

enum HistoryStoreTransactionKind: Equatable, Sendable {
    case record
    case remove
    case updateRestorable
    case clearRestorable
    case clear
    case firstUndoable
    case reload
}

struct HistoryStoreHooks: Sendable {
    let didObserveTransactionContention: @Sendable (HistoryStoreTransactionKind) -> Void

    init(
        didObserveTransactionContention:
            @escaping @Sendable (HistoryStoreTransactionKind) -> Void = { _ in }
    ) {
        self.didObserveTransactionContention = didObserveTransactionContention
    }
}

struct HistoryReceiptIdentity: Hashable, Sendable {
    let original: String
    let trashed: String

    init(_ receipt: RestorableItem) {
        original = Self.canonicalLocalPath(receipt.originalURL)
        trashed = Self.canonicalLocalPath(receipt.trashedURL)
    }

    private static func canonicalLocalPath(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

private enum HistoryReceiptValidation {
    static func isCanonicalLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        guard url.path == url.standardizedFileURL.path else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    static func isValid(_ receipt: RestorableItem) -> Bool {
        guard isCanonicalLocalFileURL(receipt.originalURL),
              isCanonicalLocalFileURL(receipt.trashedURL) else {
            return false
        }
        let identity = HistoryReceiptIdentity(receipt)
        return identity.original != identity.trashed
    }
}

private enum HistoryArchiveDecodeFailure: Error {
    case corrupt
    case unsupportedSchema
    case limitExceeded
    case privacyPathMetadata

    var code: String {
        switch self {
        case .corrupt: "history.archive.corrupt"
        case .unsupportedSchema: "history.archive.unsupportedSchema"
        case .limitExceeded: "history.archive.limitExceeded"
        case .privacyPathMetadata: "history.privacy.pathMetadata"
        }
    }
}

private struct HistoryArchiveDecodeFlags {
    var containsFutureData = false
}

private struct HistoryArchiveDecodeResult {
    let records: [CleaningRecord]
    let degradedCode: String?
}

private enum HistoryMetadataPrivacy {
    static func containsLocalPath(_ value: String) -> Bool {
        var normalized = value
        var sawMalformedPercentEscape = false
        var decodedPathSeparator = false
        // Every successful pass consumes at least one escaping layer. The
        // field-sized bound prevents adversarial input from turning this into
        // an unbounded normalization loop.
        let maximumPasses = max(
            1,
            min(value.utf8.count, HistoryArchiveLimits.maximumKindUTF8Bytes))
        for _ in 0..<maximumPasses {
            let pass = decodeValidPercentEscapes(in: normalized)
            sawMalformedPercentEscape = sawMalformedPercentEscape || pass.sawMalformedEscape
            decodedPathSeparator = decodedPathSeparator || pass.decodedPathSeparator
            guard pass.value != normalized else { break }
            normalized = pass.value
        }
        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        // Foundation's all-or-nothing percent decoder leaves valid escapes
        // hidden whenever an unrelated malformed `%` is present. If a valid
        // escape in that mixed input reveals a path separator, reject the
        // metadata even when attacker-controlled junk precedes the path.
        if sawMalformedPercentEscape && decodedPathSeparator { return true }
        let lower = normalized.lowercased()
        let scalars = Array(lower.unicodeScalars)
        if containsFileSchemePath(in: scalars)
            || containsPathPrefix("~/", in: scalars)
            || containsPathPrefix("./", in: scalars)
            || containsPathPrefix("../", in: scalars) {
            return true
        }
        for index in scalars.indices where scalars[index] == "/" {
            if index == scalars.startIndex { return true }
            let previous = scalars[scalars.index(before: index)]
            let nextIndex = scalars.index(after: index)
            if CharacterSet.whitespacesAndNewlines.contains(previous),
               nextIndex < scalars.endIndex,
               CharacterSet.whitespacesAndNewlines.contains(scalars[nextIndex]),
               isKnownSafeMetricSeparator(at: index, in: scalars) {
                continue
            }
            return true
        }
        return false
    }

    private static func decodeValidPercentEscapes(
        in value: String
    ) -> (value: String, sawMalformedEscape: Bool, decodedPathSeparator: Bool) {
        let source = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(source.count)
        var index = 0
        var sawMalformedEscape = false
        var decodedPathSeparator = false
        while index < source.count {
            guard source[index] == 0x25 else {
                decoded.append(source[index])
                index += 1
                continue
            }
            guard index + 2 < source.count,
                  let high = hexadecimalNibble(source[index + 1]),
                  let low = hexadecimalNibble(source[index + 2]) else {
                sawMalformedEscape = true
                decoded.append(source[index])
                index += 1
                continue
            }
            let byte = (high << 4) | low
            decoded.append(byte)
            decodedPathSeparator = decodedPathSeparator || byte == 0x2F || byte == 0x5C
            index += 3
        }
        return (
            String(decoding: decoded, as: UTF8.self),
            sawMalformedEscape,
            decodedPathSeparator)
    }

    private static func hexadecimalNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func isKnownSafeMetricSeparator(
        at slashIndex: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        let left = Array("cpu ".unicodeScalars)
        let right = Array(" memory".unicodeScalars)
        guard slashIndex >= left.count,
              slashIndex + right.count < scalars.count,
              scalars[(slashIndex - left.count)..<slashIndex].elementsEqual(left),
              scalars[(slashIndex + 1)...(slashIndex + right.count)].elementsEqual(right) else {
            return false
        }
        let leftBoundary = slashIndex - left.count
        if leftBoundary > 0,
           !isTokenBoundary(scalars[leftBoundary - 1]) {
            return false
        }
        let rightBoundary = slashIndex + right.count + 1
        if rightBoundary < scalars.count {
            let trailing = scalars[rightBoundary]
            if trailing == "/" || trailing == "\\" || !isTokenBoundary(trailing) {
                return false
            }
        }
        return true
    }

    private static func containsFileSchemePath(in scalars: [Unicode.Scalar]) -> Bool {
        let needle = Array("file:".unicodeScalars)
        guard scalars.count >= needle.count else { return false }
        for index in 0...(scalars.count - needle.count) {
            guard scalars[index..<(index + needle.count)].elementsEqual(needle) else {
                continue
            }
            guard index == 0 || isTokenBoundary(scalars[index - 1]) else { continue }
            let pathStart = index + needle.count
            guard pathStart < scalars.count else { continue }
            if scalars[pathStart] == "/"
                || (scalars[pathStart] == "~"
                    && pathStart + 1 < scalars.count
                    && scalars[pathStart + 1] == "/") {
                return true
            }
        }
        return false
    }

    private static func containsPathPrefix(
        _ prefix: String,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        let needle = Array(prefix.unicodeScalars)
        guard scalars.count >= needle.count else { return false }
        for index in 0...(scalars.count - needle.count) {
            guard scalars[index..<(index + needle.count)].elementsEqual(needle) else {
                continue
            }
            if index == 0 || isTokenBoundary(scalars[index - 1]) { return true }
        }
        return false
    }

    private static func isTokenBoundary(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.alphanumerics.contains(scalar)
            && scalar != "_"
            && scalar != "-"
            && scalar != "."
    }
}

private struct ParsedHistoryOperation {
    let id: UUID
    let parentID: UUID?
    let kind: OperationKind
    let status: HistoryOutcomeStatus
    let hasKnownStatus: Bool
    let mutation: OperationMutationFact
    let counts: OperationCounts
    let issues: [OperationIssue]
    let startedAt: Date
    let finishedAt: Date
}

private enum HistoryArchiveCodec {
    private static let schema0Keys: Set<String> = [
        "id", "date", "module", "reclaimedBytes", "removedCount", "restorable"
    ]
    private static let schema1Keys: Set<String> = [
        "schemaVersion", "id", "date", "module", "reclaimedBytes", "removedCount",
        "operation", "items"
    ]
    private static let operationKeys: Set<String> = [
        "id", "parentID", "kind", "status", "mutation", "counts", "issues",
        "startedAt", "finishedAt"
    ]
    private static let countKeys: Set<String> = [
        "requested", "succeeded", "unchanged", "skipped", "failed", "cancelled"
    ]
    private static let itemKeys: Set<String> = [
        "requestID", "intent", "disposition", "mutation", "affectedBytes", "receipt"
    ]
    private static let dispositionKeys: Set<String> = ["kind", "issue"]
    private static let issueKeys: Set<String> = [
        "code", "category", "subjectID", "recovery", "retryable"
    ]
    private static let receiptKeys: Set<String> = ["originalURL", "trashedURL"]

    static func decode(_ data: Data) -> HistoryArchiveDecodeResult {
        guard data.count <= HistoryArchiveLimits.maximumArchiveBytes else {
            return HistoryArchiveDecodeResult(
                records: [], degradedCode: HistoryArchiveDecodeFailure.limitExceeded.code)
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return HistoryArchiveDecodeResult(
                records: [], degradedCode: HistoryArchiveDecodeFailure.corrupt.code)
        }
        guard let elements = root as? [Any] else {
            return HistoryArchiveDecodeResult(
                records: [], degradedCode: HistoryArchiveDecodeFailure.corrupt.code)
        }
        guard elements.count <= HistoryArchiveLimits.maximumRecords else {
            return HistoryArchiveDecodeResult(
                records: [], degradedCode: HistoryArchiveDecodeFailure.limitExceeded.code)
        }

        var decoded: [(offset: Int, record: CleaningRecord)] = []
        var degradedCode: String?
        for (offset, element) in elements.enumerated() {
            guard let object = element as? [String: Any] else {
                degradedCode = degradedCode ?? HistoryArchiveDecodeFailure.corrupt.code
                continue
            }
            var flags = HistoryArchiveDecodeFlags()
            do {
                var record = try parseRecord(object, flags: &flags)
                if flags.containsFutureData {
                    degradedCode = degradedCode ?? "history.archive.futureData"
                    if record.schemaVersion == 1 {
                        record = record.untrustedFutureDataCopy()
                    }
                }
                decoded.append((offset, record))
            } catch let failure as HistoryArchiveDecodeFailure {
                degradedCode = preferredCode(degradedCode, failure.code)
                if let fallback = fallbackRecord(from: object) {
                    decoded.append((offset, fallback))
                }
            } catch {
                degradedCode = degradedCode ?? HistoryArchiveDecodeFailure.corrupt.code
                if let fallback = fallbackRecord(from: object) {
                    decoded.append((offset, fallback))
                }
            }
        }

        var canonical: [CleaningRecord] = []
        var operationIndexes: [UUID: Int] = [:]
        for entry in decoded {
            let record = entry.record
            guard let operationID = record.operationID else {
                canonical.append(record)
                continue
            }
            guard let existingIndex = operationIndexes[operationID] else {
                operationIndexes[operationID] = canonical.count
                canonical.append(record)
                continue
            }
            degradedCode = degradedCode ?? "history.archive.duplicateOperationID"
            let existing = canonical[existingIndex]
            if !existing.hasSameImmutableOperationFacts(as: record) {
                canonical[existingIndex] = existing.untrustedDuplicateConflictCopy()
            } else if !existing.isTrustedForAggregates || !record.isTrustedForAggregates {
                canonical[existingIndex] = existing.untrustedFutureDataCopy()
            }
        }
        return HistoryArchiveDecodeResult(records: canonical, degradedCode: degradedCode)
    }

    static func encode(_ records: [CleaningRecord]) throws -> Data {
        let objects = try records.map(encodeRecord)
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        guard data.count <= HistoryArchiveLimits.maximumArchiveBytes else {
            throw HistoryArchiveDecodeFailure.limitExceeded
        }
        return data
    }

    private static func parseRecord(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> CleaningRecord {
        if object["schemaVersion"] == nil {
            guard object["operation"] == nil, object["items"] == nil else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            return try parseSchema0(object, flags: &flags)
        }
        guard let version = integer(object["schemaVersion"]), version == 1 else {
            if let version = integer(object["schemaVersion"]), version > 1 {
                throw HistoryArchiveDecodeFailure.unsupportedSchema
            }
            throw HistoryArchiveDecodeFailure.corrupt
        }
        return try parseSchema1(object, flags: &flags)
    }

    private static func parseSchema0(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> CleaningRecord {
        try validateKeys(
            object,
            allowed: schema0Keys,
            required: ["id", "date", "module", "reclaimedBytes", "removedCount"],
            flags: &flags)
        guard let id = uuid(object["id"]),
              let date = date(object["date"]),
              let module = object["module"] as? String,
              let reclaimedBytes = int64(object["reclaimedBytes"]), reclaimedBytes >= 0,
              let removedCount = integer(object["removedCount"]), removedCount >= 0 else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        try validateLength(module, maximum: HistoryArchiveLimits.maximumModuleUTF8Bytes)
        try rejectPathMetadata(module)
        var restorable: [RestorableItem] = []
        if let raw = object["restorable"] {
            guard let values = raw as? [Any] else { throw HistoryArchiveDecodeFailure.corrupt }
            restorable = try values.map { value in
                guard let receipt = value as? [String: Any] else {
                    throw HistoryArchiveDecodeFailure.corrupt
                }
                return try parseReceipt(receipt, flags: &flags)
            }
            try validateReceiptUniqueness(restorable)
        }
        return CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: reclaimedBytes,
            removedCount: removedCount,
            restorable: restorable,
            schemaVersion: 0,
            operationID: nil,
            parentOperationID: nil,
            operationKind: nil,
            outcomeStatus: .legacyUnknown,
            mutation: nil,
            counts: nil,
            itemFacts: [],
            isTrustedForAggregates: true)
    }

    private static func parseSchema1(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> CleaningRecord {
        try validateKeys(
            object,
            allowed: schema1Keys,
            required: schema1Keys,
            flags: &flags)
        guard let id = uuid(object["id"]),
              let date = date(object["date"]),
              let module = object["module"] as? String,
              let reclaimedBytes = int64(object["reclaimedBytes"]), reclaimedBytes >= 0,
              let removedCount = integer(object["removedCount"]), removedCount >= 0,
              let operationObject = object["operation"] as? [String: Any],
              let itemObjects = object["items"] as? [Any] else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        try validateLength(module, maximum: HistoryArchiveLimits.maximumModuleUTF8Bytes)
        try rejectPathMetadata(module)
        guard itemObjects.count <= HistoryArchiveLimits.maximumItemFactsPerRecord else {
            throw HistoryArchiveDecodeFailure.limitExceeded
        }
        let operation = try parseOperation(operationObject, flags: &flags)
        let itemFacts = try itemObjects.map { raw -> HistoryItemFact in
            guard let item = raw as? [String: Any] else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            return try parseItem(item, flags: &flags)
        }
        try validateV1Facts(
            operation: operation,
            items: itemFacts,
            reclaimedBytes: reclaimedBytes,
            removedCount: removedCount)
        let restorable = itemFacts.compactMap(\.receipt)
        return CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: reclaimedBytes,
            removedCount: removedCount,
            restorable: restorable,
            schemaVersion: 1,
            operationID: operation.id,
            parentOperationID: operation.parentID,
            operationKind: operation.kind,
            outcomeStatus: operation.hasKnownStatus ? operation.status : .legacyUnknown,
            mutation: operation.mutation,
            counts: operation.counts,
            itemFacts: itemFacts,
            startedAt: operation.startedAt,
            finishedAt: operation.finishedAt,
            issues: operation.issues,
            isTrustedForAggregates: operation.hasKnownStatus)
    }

    private static func parseOperation(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> ParsedHistoryOperation {
        try validateKeys(
            object,
            allowed: operationKeys,
            required: [
                "id", "kind", "status", "mutation", "counts", "issues",
                "startedAt", "finishedAt"
            ],
            flags: &flags)
        guard let id = uuid(object["id"]),
              let kindValue = object["kind"] as? String,
              let statusValue = object["status"] as? String,
              let mutationValue = object["mutation"] as? String,
              let mutation = OperationMutationFact(rawValue: mutationValue),
              let countObject = object["counts"] as? [String: Any],
              let issueObjects = object["issues"] as? [Any],
              let startedAt = date(object["startedAt"]),
              let finishedAt = date(object["finishedAt"]),
              finishedAt >= startedAt else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        try validateLength(kindValue, maximum: HistoryArchiveLimits.maximumKindUTF8Bytes)
        try rejectPathMetadata(kindValue)
        guard issueObjects.count <= HistoryArchiveLimits.maximumIssuesPerOperation else {
            throw HistoryArchiveDecodeFailure.limitExceeded
        }
        let parentID: UUID?
        if let rawParent = object["parentID"] {
            guard let parsed = uuid(rawParent) else { throw HistoryArchiveDecodeFailure.corrupt }
            parentID = parsed
        } else {
            parentID = nil
        }
        try validateKeys(
            countObject,
            allowed: countKeys,
            required: countKeys,
            flags: &flags)
        guard let requested = nonnegativeInteger(countObject["requested"]),
              let succeeded = nonnegativeInteger(countObject["succeeded"]),
              let unchanged = nonnegativeInteger(countObject["unchanged"]),
              let skipped = nonnegativeInteger(countObject["skipped"]),
              let failed = nonnegativeInteger(countObject["failed"]),
              let cancelled = nonnegativeInteger(countObject["cancelled"]) else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let counts = OperationCounts(
            requested: requested,
            succeeded: succeeded,
            unchanged: unchanged,
            skipped: skipped,
            failed: failed,
            cancelled: cancelled)
        let issues = try issueObjects.map { raw -> OperationIssue in
            guard let issue = raw as? [String: Any] else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            return try parseIssue(issue, flags: &flags)
        }
        let status: HistoryOutcomeStatus
        let hasKnownStatus: Bool
        if let known = HistoryOutcomeStatus(rawValue: statusValue), known != .legacyUnknown {
            status = known
            hasKnownStatus = true
        } else {
            status = .legacyUnknown
            hasKnownStatus = false
            flags.containsFutureData = true
        }
        return ParsedHistoryOperation(
            id: id,
            parentID: parentID,
            kind: OperationKind(kindValue),
            status: status,
            hasKnownStatus: hasKnownStatus,
            mutation: mutation,
            counts: counts,
            issues: issues,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }

    private static func parseItem(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> HistoryItemFact {
        try validateKeys(
            object,
            allowed: itemKeys,
            required: ["requestID", "intent", "disposition", "mutation", "affectedBytes"],
            flags: &flags)
        guard let requestID = uuid(object["requestID"]),
              let intentValue = object["intent"] as? String,
              let intent = deleteIntent(intentValue),
              let dispositionObject = object["disposition"] as? [String: Any],
              let mutationValue = object["mutation"] as? String,
              let mutation = OperationMutationFact(rawValue: mutationValue),
              let affectedBytes = int64(object["affectedBytes"]), affectedBytes >= 0 else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let disposition = try parseDisposition(dispositionObject, flags: &flags)
        let receipt: RestorableItem?
        if let rawReceipt = object["receipt"] {
            guard let receiptObject = rawReceipt as? [String: Any] else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            receipt = try parseReceipt(receiptObject, flags: &flags)
        } else {
            receipt = nil
        }
        return HistoryItemFact(
            requestID: requestID,
            intent: intent,
            disposition: disposition,
            mutation: mutation,
            affectedBytes: affectedBytes,
            receipt: receipt)
    }

    private static func parseDisposition(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> OperationDisposition {
        try validateKeys(
            object,
            allowed: dispositionKeys,
            required: ["kind"],
            flags: &flags)
        guard let kind = object["kind"] as? String else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let issue: OperationIssue?
        if let rawIssue = object["issue"] {
            guard let issueObject = rawIssue as? [String: Any] else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            issue = try parseIssue(issueObject, flags: &flags)
        } else {
            issue = nil
        }
        switch kind {
        case "succeeded":
            guard issue == nil else { throw HistoryArchiveDecodeFailure.corrupt }
            return .succeeded
        case "unchanged":
            guard issue == nil else { throw HistoryArchiveDecodeFailure.corrupt }
            return .unchanged
        case "skipped":
            guard let issue else { throw HistoryArchiveDecodeFailure.corrupt }
            return .skipped(issue)
        case "failed":
            guard let issue else { throw HistoryArchiveDecodeFailure.corrupt }
            return .failed(issue)
        case "cancelled":
            return .cancelled(issue)
        default:
            throw HistoryArchiveDecodeFailure.corrupt
        }
    }

    private static func parseIssue(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> OperationIssue {
        try validateKeys(
            object,
            allowed: issueKeys,
            required: ["code", "category", "recovery", "retryable"],
            flags: &flags)
        guard let code = object["code"] as? String,
              let categoryValue = object["category"] as? String,
              let category = OperationIssueCategory(rawValue: categoryValue),
              let recoveryValue = object["recovery"] as? String,
              let recovery = OperationRecoveryHint(rawValue: recoveryValue),
              let retryable = boolean(object["retryable"]) else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        try validateLength(code, maximum: HistoryArchiveLimits.maximumCodeUTF8Bytes)
        try rejectPathMetadata(code)
        let subjectID: String?
        if let rawSubject = object["subjectID"] {
            guard let subject = rawSubject as? String else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            try validateLength(subject, maximum: HistoryArchiveLimits.maximumSubjectUTF8Bytes)
            try rejectPathMetadata(subject)
            subjectID = subject
        } else {
            subjectID = nil
        }
        return OperationIssue(
            code: code,
            category: category,
            subjectID: subjectID,
            recovery: recovery,
            retryable: retryable)
    }

    private static func parseReceipt(
        _ object: [String: Any],
        flags: inout HistoryArchiveDecodeFlags
    ) throws -> RestorableItem {
        try validateKeys(
            object,
            allowed: receiptKeys,
            required: receiptKeys,
            flags: &flags)
        guard let originalValue = object["originalURL"] as? String,
              let trashedValue = object["trashedURL"] as? String,
              let originalURL = URL(string: originalValue),
              let trashedURL = URL(string: trashedValue),
              HistoryReceiptValidation.isCanonicalLocalFileURL(originalURL),
              HistoryReceiptValidation.isCanonicalLocalFileURL(trashedURL) else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        return RestorableItem(originalURL: originalURL, trashedURL: trashedURL)
    }

    private static func validateV1Facts(
        operation: ParsedHistoryOperation,
        items: [HistoryItemFact],
        reclaimedBytes: Int64,
        removedCount: Int
    ) throws {
        guard !items.isEmpty,
              operation.counts.requested == items.count,
              countsTotalMatchesRequested(operation.counts) else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let requestStrings = items.map { $0.requestID.uuidString }
        guard Set(requestStrings).count == requestStrings.count else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let requestSet = Set(requestStrings)
        for issue in operation.issues {
            if let subject = issue.subjectID, !requestSet.contains(subject) {
                throw HistoryArchiveDecodeFailure.corrupt
            }
        }
        for item in items {
            if let issue = dispositionIssue(item.disposition),
               let subject = issue.subjectID,
               !requestSet.contains(subject) {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            if item.disposition != .succeeded, item.affectedBytes != 0 {
                throw HistoryArchiveDecodeFailure.corrupt
            }
            if item.receipt != nil,
               !(item.intent == .trash
                    && item.disposition == .succeeded
                    && item.mutation == .changed) {
                throw HistoryArchiveDecodeFailure.corrupt
            }
        }
        try validateReceiptUniqueness(items.compactMap(\.receipt))
        let outcomes = items.map {
            OperationItemOutcome(
                subjectID: $0.requestID.uuidString,
                disposition: $0.disposition,
                mutation: $0.mutation,
                affectedBytes: $0.affectedBytes)
        }
        let reduced: OperationOutcome
        do {
            reduced = try OperationOutcomeReducer.reduce(
                id: operation.id,
                parentID: operation.parentID,
                kind: operation.kind,
                requestedSubjectIDs: requestStrings,
                itemOutcomes: outcomes,
                cancellationAccepted: operation.status == .cancelled,
                startedAt: operation.startedAt,
                finishedAt: operation.finishedAt)
        } catch {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        guard reduced.counts == operation.counts,
              reduced.mutation == operation.mutation,
              reduced.issues == operation.issues,
              !operation.hasKnownStatus || HistoryOutcomeStatus(reduced.status) == operation.status,
              removedCount == operation.counts.succeeded else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        let summed = items.reduce(Int64(0)) { total, item in
            guard item.disposition == .succeeded else { return total }
            return saturatingAdd(total, item.affectedBytes)
        }
        guard summed == reclaimedBytes else { throw HistoryArchiveDecodeFailure.corrupt }
    }

    private static func encodeRecord(_ record: CleaningRecord) throws -> [String: Any] {
        if record.schemaVersion == 0 {
            var object: [String: Any] = [
                "id": record.id.uuidString,
                "date": record.date.timeIntervalSinceReferenceDate,
                "module": record.module,
                "reclaimedBytes": record.reclaimedBytes,
                "removedCount": record.removedCount
            ]
            if !record.restorable.isEmpty {
                object["restorable"] = record.restorable.map(encodeReceipt)
            }
            return object
        }
        guard record.schemaVersion == 1,
              let operationID = record.operationID,
              let operationKind = record.operationKind,
              let mutation = record.mutation,
              let counts = record.counts,
              let startedAt = record.startedAt,
              let finishedAt = record.finishedAt,
              record.outcomeStatus != .legacyUnknown else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        var operation: [String: Any] = [
            "id": operationID.uuidString,
            "kind": operationKind.rawValue,
            "status": record.outcomeStatus.rawValue,
            "mutation": mutation.rawValue,
            "counts": [
                "requested": counts.requested,
                "succeeded": counts.succeeded,
                "unchanged": counts.unchanged,
                "skipped": counts.skipped,
                "failed": counts.failed,
                "cancelled": counts.cancelled
            ],
            "issues": record.issues.map(encodeIssue),
            "startedAt": startedAt.timeIntervalSinceReferenceDate,
            "finishedAt": finishedAt.timeIntervalSinceReferenceDate
        ]
        if let parent = record.parentOperationID { operation["parentID"] = parent.uuidString }
        return [
            "schemaVersion": 1,
            "id": record.id.uuidString,
            "date": record.date.timeIntervalSinceReferenceDate,
            "module": record.module,
            "reclaimedBytes": record.reclaimedBytes,
            "removedCount": record.removedCount,
            "operation": operation,
            "items": record.itemFacts.map(encodeItem)
        ]
    }

    private static func encodeItem(_ item: HistoryItemFact) -> [String: Any] {
        var object: [String: Any] = [
            "requestID": item.requestID.uuidString,
            "intent": item.intent == .trash ? "trash" : "permanent",
            "disposition": encodeDisposition(item.disposition),
            "mutation": item.mutation.rawValue,
            "affectedBytes": item.affectedBytes
        ]
        if let receipt = item.receipt { object["receipt"] = encodeReceipt(receipt) }
        return object
    }

    private static func encodeDisposition(_ disposition: OperationDisposition) -> [String: Any] {
        switch disposition {
        case .succeeded:
            return ["kind": "succeeded"]
        case .unchanged:
            return ["kind": "unchanged"]
        case let .skipped(issue):
            return ["kind": "skipped", "issue": encodeIssue(issue)]
        case let .failed(issue):
            return ["kind": "failed", "issue": encodeIssue(issue)]
        case let .cancelled(issue):
            var value: [String: Any] = ["kind": "cancelled"]
            if let issue { value["issue"] = encodeIssue(issue) }
            return value
        }
    }

    private static func encodeIssue(_ issue: OperationIssue) -> [String: Any] {
        var object: [String: Any] = [
            "code": issue.code,
            "category": issue.category.rawValue,
            "recovery": issue.recovery.rawValue,
            "retryable": issue.retryable
        ]
        if let subject = issue.subjectID { object["subjectID"] = subject }
        return object
    }

    private static func encodeReceipt(_ receipt: RestorableItem) -> [String: Any] {
        [
            "originalURL": receipt.originalURL.absoluteString,
            "trashedURL": receipt.trashedURL.absoluteString
        ]
    }

    private static func fallbackRecord(from object: [String: Any]) -> CleaningRecord? {
        guard let id = uuid(object["id"]),
              let date = date(object["date"]),
              let module = object["module"] as? String,
              module.utf8.count <= HistoryArchiveLimits.maximumModuleUTF8Bytes,
              !HistoryMetadataPrivacy.containsLocalPath(module) else {
            return nil
        }
        let version = integer(object["schemaVersion"]) ?? 0
        return CleaningRecord(
            id: id,
            date: date,
            module: module,
            reclaimedBytes: 0,
            removedCount: 0,
            restorable: [],
            schemaVersion: max(0, version),
            operationID: nil,
            parentOperationID: nil,
            operationKind: nil,
            outcomeStatus: .legacyUnknown,
            mutation: nil,
            counts: nil,
            itemFacts: [],
            isTrustedForAggregates: false)
    }

    private static func validateKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        flags: inout HistoryArchiveDecodeFlags
    ) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual) else {
            throw HistoryArchiveDecodeFailure.corrupt
        }
        if !actual.isSubset(of: allowed) { flags.containsFutureData = true }
    }

    private static func validateReceiptUniqueness(
        _ receipts: [RestorableItem]
    ) throws {
        var pairs = Set<HistoryReceiptIdentity>()
        var locations = Set<String>()
        for receipt in receipts {
            let identity = HistoryReceiptIdentity(receipt)
            guard pairs.insert(identity).inserted,
                  locations.insert(identity.original).inserted,
                  locations.insert(identity.trashed).inserted else {
                throw HistoryArchiveDecodeFailure.corrupt
            }
        }
    }

    private static func validateLength(_ value: String, maximum: Int) throws {
        guard value.utf8.count <= maximum else {
            throw HistoryArchiveDecodeFailure.limitExceeded
        }
    }

    private static func rejectPathMetadata(_ value: String) throws {
        if HistoryMetadataPrivacy.containsLocalPath(value) {
            throw HistoryArchiveDecodeFailure.privacyPathMetadata
        }
    }

    private static func countsTotalMatchesRequested(_ counts: OperationCounts) -> Bool {
        var total = 0
        for value in [
            counts.succeeded,
            counts.unchanged,
            counts.skipped,
            counts.failed,
            counts.cancelled
        ] {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return false }
            total = sum
        }
        return total == counts.requested
    }

    private static func preferredCode(_ current: String?, _ candidate: String) -> String {
        if candidate == HistoryArchiveDecodeFailure.limitExceeded.code { return candidate }
        return current ?? candidate
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let raw = int64(value), raw <= Int64(Int.max), raw >= Int64(Int.min) else {
            return nil
        }
        return Int(raw)
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let value = integer(value), value >= 0 else { return nil }
        return value
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max) else { return nil }
        let result = number.int64Value
        guard NSNumber(value: result).doubleValue == double else { return nil }
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }

    private static func deleteIntent(_ value: String) -> DeleteIntent? {
        switch value {
        case "trash": .trash
        case "permanent": .permanent
        default: nil
        }
    }

    private static func dispositionIssue(_ disposition: OperationDisposition) -> OperationIssue? {
        switch disposition {
        case let .skipped(issue), let .failed(issue): issue
        case let .cancelled(issue): issue
        case .succeeded, .unchanged: nil
        }
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? .max : sum
    }
}

private struct HistoryReadModel {
    var records: [CleaningRecord]
    var revision: HistoryRevision
    var state: HistoryArchiveState
}

private enum HistoryMutationPreparation<Value> {
    case candidate(records: [CleaningRecord], value: Value)
    case noCommit(value: Value)
    case rejected(code: String)
}

private enum HistoryMutationExecution<Value> {
    case completed(Value)
    case rejected(code: String)
}

private enum HistoryCodeResult<Value> {
    case success(Value)
    case failure(String)
}

private struct ValidatedHistoryRecordCandidate: Sendable {
    let record: CleaningRecord
}

public final class HistoryStore: OutcomeHistoryWriting, @unchecked Sendable {
    private let readLock = NSLock()
    private let transactionLock = NSLock()
    private let persistence: any HistoryPersistence
    private let hooks: HistoryStoreHooks
    private var readModel: HistoryReadModel

    public convenience init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory()
        self.init(
            directory: directory,
            persistence: LiveHistoryPersistence(directory: directory),
            hooks: HistoryStoreHooks())
    }

    init(
        directory: URL,
        persistence: any HistoryPersistence,
        hooks: HistoryStoreHooks = HistoryStoreHooks()
    ) {
        _ = directory
        self.persistence = persistence
        self.hooks = hooks
        self.readModel = Self.initialModel(from: persistence.load())
    }

    var archiveState: HistoryArchiveState {
        withReadModel { $0.state }
    }

    public func reload() -> HistoryReloadResult {
        withTransactionLock(kind: .reload) {
            let prior = snapshot()
            switch Self.verifiedModel(from: persistence.load()) {
            case let .success(model):
                publish(model)
                return .writable
            case let .failure(code):
                var degraded = prior
                degraded.state = .degradedReadOnly(code: code)
                publish(degraded)
                return .degraded(code: code)
            }
        }
    }

    @discardableResult
    public func record(
        module: String,
        report: CleaningReport,
        date: Date = Date()
    ) -> HistoryRecordResult {
        let candidate: ValidatedHistoryRecordCandidate
        switch Self.makeTypedCandidate(module: module, report: report, date: date) {
        case let .success(value): candidate = value
        case let .failure(code): return .rejected(code: code)
        }
        return record(candidate)
    }

    @discardableResult
    public func record(
        module: String,
        result: OperationResult<ShredderPayload>,
        date: Date = Date()
    ) -> HistoryRecordResult {
        let candidate: ValidatedHistoryRecordCandidate
        switch Self.makeTypedCandidate(module: module, result: result, date: date) {
        case let .success(value): candidate = value
        case let .failure(code): return .rejected(code: code)
        }
        return record(candidate)
    }

    private func record(
        _ candidate: ValidatedHistoryRecordCandidate
    ) -> HistoryRecordResult {
        let operationID = candidate.record.operationID
        let execution = executeMutation(kind: .record) { records in
            if let operationID,
               let existing = records.first(where: { $0.operationID == operationID }) {
                if existing.hasSameImmutableOperationFacts(as: candidate.record) {
                    return .noCommit(value: HistoryRecordResult.alreadyRecorded(
                        recordID: existing.id))
                }
                return .rejected(code: "history.operation.conflict")
            }
            guard candidate.record.mutation != OperationMutationFact.none else {
                return .noCommit(value: HistoryRecordResult.notRecordedNoChanges)
            }
            guard let updated = Self.insertingWithRetention(
                candidate.record,
                into: records
            ) else {
                return .rejected(code: "history.retention.tooOld")
            }
            return .candidate(
                records: updated,
                value: .inserted(recordID: candidate.record.id))
        }
        switch execution {
        case let .completed(result): return result
        case let .rejected(code): return .rejected(code: code)
        }
    }

    @discardableResult
    public func record(
        module: String,
        reclaimedBytes: Int64,
        removedCount: Int,
        restorable: [RestorableItem] = [],
        date: Date = Date()
    ) -> UUID? {
        guard reclaimedBytes > 0 || removedCount > 0 else { return nil }
        guard module.utf8.count <= HistoryArchiveLimits.maximumModuleUTF8Bytes,
              !Self.containsPathMetadata(module),
              restorable.allSatisfy(HistoryReceiptValidation.isValid),
              Self.receiptsAreUnique(restorable) else { return nil }
        let record = CleaningRecord(
            id: UUID(),
            date: date,
            module: module,
            reclaimedBytes: max(0, reclaimedBytes),
            removedCount: max(0, removedCount),
            restorable: restorable,
            schemaVersion: 0,
            operationID: nil,
            parentOperationID: nil,
            operationKind: nil,
            outcomeStatus: .legacyUnknown,
            mutation: nil,
            counts: nil,
            itemFacts: [],
            isTrustedForAggregates: true)
        let execution: HistoryMutationExecution<UUID> = executeMutation(
            kind: .record
        ) { records in
            guard let updated = Self.insertingWithRetention(record, into: records) else {
                return .rejected(code: "history.retention.tooOld")
            }
            return .candidate(records: updated, value: record.id)
        }
        guard case let .completed(id) = execution else { return nil }
        return id
    }

    @discardableResult
    public func remove(id: UUID) -> HistoryUpdateResult {
        updateResult(executeMutation(kind: .remove) { records in
            guard records.contains(where: { $0.id == id }) else {
                return .noCommit(value: HistoryUpdateResult.notFound)
            }
            return .candidate(
                records: records.filter { $0.id != id },
                value: .committed)
        })
    }

    @discardableResult
    public func updateRestorable(
        id: UUID,
        to items: [RestorableItem]
    ) -> HistoryUpdateResult {
        updateResult(executeMutation(kind: .updateRestorable) { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return .noCommit(value: HistoryUpdateResult.notFound)
            }
            let record = records[index]
            guard Self.isRemoveOnlyReceiptUpdate(existing: record.restorable, requested: items) else {
                return .rejected(code: "history.receipt.notRemoveOnly")
            }
            var updated = records
            updated[index] = record.updatingRestorable(items)
            return .candidate(records: updated, value: .committed)
        })
    }

    @discardableResult
    public func clearRestorable(id: UUID) -> HistoryUpdateResult {
        updateResult(executeMutation(kind: .clearRestorable) { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return .noCommit(value: HistoryUpdateResult.notFound)
            }
            var updated = records
            updated[index] = updated[index].updatingRestorable([])
            return .candidate(records: updated, value: .committed)
        })
    }

    @discardableResult
    public func clear() -> HistoryUpdateResult {
        updateResult(executeMutation(kind: .clear) { _ in
            .candidate(records: [], value: .committed)
        })
    }

    public func recent(_ limit: Int = 20) -> [CleaningRecord] {
        guard limit > 0 else { return [] }
        return withReadModel { Array($0.records.prefix(limit)) }
    }

    public func firstUndoable(
        within limit: Int = 3,
        existsInTrash: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> CleaningRecord? {
        guard limit > 0 else { return nil }
        let execution: HistoryMutationExecution<CleaningRecord?> = executeMutation(
            kind: .firstUndoable,
            retryNoCommitAsCandidate: true
        ) { records in
            var updated = records
            var changed = false
            var selected: CleaningRecord?
            for index in updated.indices.prefix(limit) {
                let record = updated[index]
                guard !record.restorable.isEmpty else { continue }
                let alive = record.restorable.filter { existsInTrash($0.trashedURL) }
                if alive.count != record.restorable.count {
                    updated[index] = record.updatingRestorable(alive)
                    changed = true
                }
                if !alive.isEmpty {
                    selected = updated[index]
                    break
                }
            }
            if changed { return .candidate(records: updated, value: selected) }
            return .noCommit(value: selected)
        }
        guard case let .completed(record) = execution else { return nil }
        return record
    }

    public var totalHistoryRecords: Int {
        withReadModel { $0.records.count }
    }

    public var totalSuccessfulCleanups: Int {
        withReadModel { model in
            model.records.reduce(into: 0) { total, record in
                guard record.schemaVersion == 1,
                      record.isTrustedForAggregates,
                      record.outcomeStatus == .success,
                      record.mutation == .changed,
                      let counts = record.counts,
                      counts.succeeded > 0,
                      record.removedCount == counts.succeeded,
                      counts.requested == record.itemFacts.count else { return }
                total += 1
            }
        }
    }

    public var totalReclaimedAllTime: Int64 {
        withReadModel { model in
            model.records.reduce(Int64(0)) { total, record in
                let factual: Int64
                if record.schemaVersion == 0, record.isTrustedForAggregates {
                    factual = max(0, record.reclaimedBytes)
                } else if record.schemaVersion == 1, record.isTrustedForAggregates {
                    factual = record.itemFacts.reduce(Int64(0)) { itemTotal, item in
                        guard item.disposition == .succeeded,
                              item.mutation == .changed || item.mutation == .possiblyChanged else {
                            return itemTotal
                        }
                        return Self.saturatingAdd(itemTotal, item.affectedBytes)
                    }
                } else {
                    factual = 0
                }
                return Self.saturatingAdd(total, factual)
            }
        }
    }

    public var totalCleanups: Int { totalHistoryRecords }

    private func executeMutation<Value>(
        kind: HistoryStoreTransactionKind,
        retryNoCommitAsCandidate: Bool = false,
        prepare: ([CleaningRecord]) -> HistoryMutationPreparation<Value>
    ) -> HistoryMutationExecution<Value> {
        withTransactionLock(kind: kind) {
            let original = snapshot()
            guard original.state == .writable else {
                return .rejected(code: "history.archive.readOnly")
            }
            var base = original
            var observedVerifiedConflict = false
            var attempts = 0
            while true {
                let records: [CleaningRecord]
                let value: Value
                switch prepare(base.records) {
                case let .noCommit(noCommitValue):
                    guard observedVerifiedConflict && retryNoCommitAsCandidate else {
                        if observedVerifiedConflict { publish(base) }
                        return .completed(noCommitValue)
                    }
                    records = base.records
                    value = noCommitValue
                case let .rejected(code):
                    if observedVerifiedConflict { publish(base) }
                    return .rejected(code: code)
                case let .candidate(candidateRecords, candidateValue):
                    records = candidateRecords
                    value = candidateValue
                }
                let data: Data
                do {
                    data = try HistoryArchiveCodec.encode(records)
                } catch let failure as HistoryArchiveDecodeFailure {
                    if observedVerifiedConflict { publish(base) }
                    return .rejected(code: failure.code)
                } catch {
                    if observedVerifiedConflict { publish(base) }
                    return .rejected(code: "history.archive.encodeFailed")
                }
                attempts += 1
                switch persistence.commit(data, expectedRevision: base.revision) {
                    case let .committed(newRevision):
                        guard Self.revision(newRevision, matches: data) else {
                            var degraded = original
                            degraded.state = .degradedReadOnly(
                                code: "history.persistence.invalidRevision")
                            publish(degraded)
                            return .rejected(code: "history.persistence.invalidRevision")
                        }
                        publish(HistoryReadModel(
                            records: records,
                            revision: newRevision,
                            state: .writable))
                        return .completed(value)
                    case let .failed(code):
                        if Self.failureRequiresDegradation(code) {
                            var degraded = observedVerifiedConflict ? base : original
                            degraded.state = .degradedReadOnly(code: code)
                            publish(degraded)
                        } else if observedVerifiedConflict {
                            publish(base)
                        }
                        return .rejected(code: code)
                    case let .conflict(latest):
                        guard attempts < 8 else {
                            return .rejected(code: "history.persistence.conflictExhausted")
                        }
                        switch Self.verifiedModel(from: latest) {
                        case let .success(latestModel):
                            base = latestModel
                            observedVerifiedConflict = true
                        case let .failure(code):
                            var degraded = original
                            degraded.state = .degradedReadOnly(code: code)
                            publish(degraded)
                            return .rejected(code: code)
                        }
                    case let .indeterminate(latest, _):
                        var honest = original
                        if let latest,
                           case let .success(observed) = Self.verifiedModel(from: latest) {
                            honest = observed
                        }
                        honest.state = .degradedReadOnly(
                            code: "history.persistence.durabilityUnknown")
                        publish(honest)
                        return .rejected(code: "history.persistence.durabilityUnknown")
                }
            }
        }
    }

    private func updateResult(
        _ execution: HistoryMutationExecution<HistoryUpdateResult>
    ) -> HistoryUpdateResult {
        switch execution {
        case let .completed(result): result
        case let .rejected(code): .rejected(code: code)
        }
    }

    private func withTransactionLock<Value>(
        kind: HistoryStoreTransactionKind,
        _ body: () -> Value
    ) -> Value {
        if !transactionLock.try() {
            hooks.didObserveTransactionContention(kind)
            transactionLock.lock()
        }
        defer { transactionLock.unlock() }
        return body()
    }

    private func withReadModel<Value>(_ body: (HistoryReadModel) -> Value) -> Value {
        readLock.lock()
        let current = readModel
        readLock.unlock()
        return body(current)
    }

    private func snapshot() -> HistoryReadModel {
        withReadModel { $0 }
    }

    private func publish(_ model: HistoryReadModel) {
        readLock.lock()
        readModel = model
        readLock.unlock()
    }

    private static func initialModel(from result: HistoryLoadResult) -> HistoryReadModel {
        switch result {
        case .missing:
            return HistoryReadModel(records: [], revision: .missing, state: .writable)
        case let .failed(code):
            return HistoryReadModel(
                records: [], revision: .missing, state: .degradedReadOnly(code: code))
        case let .loaded(snapshot):
            guard revision(snapshot.revision, matches: snapshot.data) else {
                return HistoryReadModel(
                    records: [],
                    revision: .missing,
                    state: .degradedReadOnly(code: "history.persistence.invalidRevision"))
            }
            let decoded = HistoryArchiveCodec.decode(snapshot.data)
            return HistoryReadModel(
                records: decoded.records,
                revision: snapshot.revision,
                state: decoded.degradedCode.map(HistoryArchiveState.degradedReadOnly)
                    ?? .writable)
        }
    }

    private static func verifiedModel(
        from result: HistoryLoadResult
    ) -> HistoryCodeResult<HistoryReadModel> {
        switch result {
        case .missing:
            return .success(HistoryReadModel(
                records: [], revision: .missing, state: .writable))
        case let .failed(code):
            return .failure(code)
        case let .loaded(snapshot):
            guard revision(snapshot.revision, matches: snapshot.data) else {
                return .failure("history.persistence.invalidRevision")
            }
            let decoded = HistoryArchiveCodec.decode(snapshot.data)
            if let code = decoded.degradedCode { return .failure(code) }
            return .success(HistoryReadModel(
                records: decoded.records,
                revision: snapshot.revision,
                state: .writable))
        }
    }

    private static func revision(_ revision: HistoryRevision, matches data: Data) -> Bool {
        guard revision.isWellFormed else { return false }
        return revision == HistoryRevision.digest(of: data)
    }

    private static func makeTypedCandidate(
        module: String,
        report: CleaningReport,
        date: Date
    ) -> HistoryCodeResult<ValidatedHistoryRecordCandidate> {
        guard report.items.count <= HistoryArchiveLimits.maximumItemFactsPerRecord else {
            return .failure("history.archive.limitExceeded")
        }
        let facts = report.items.map {
            HistoryItemFact(
                requestID: $0.requestID,
                intent: $0.intent,
                disposition: $0.disposition,
                mutation: $0.mutation,
                affectedBytes: $0.reclaimedBytes,
                receipt: $0.restorable)
        }
        return makeTypedCandidate(
            module: module,
            operation: report.operation,
            facts: facts,
            reportedReclaimedBytes: report.reclaimedBytes,
            reportedRemovedCount: report.removedCount,
            date: date)
    }

    private static func makeTypedCandidate(
        module: String,
        result: OperationResult<ShredderPayload>,
        date: Date
    ) -> HistoryCodeResult<ValidatedHistoryRecordCandidate> {
        guard result.outcome.kind == .shred else {
            return .failure("history.operation.invalidFacts")
        }
        guard result.payload.items.count <= HistoryArchiveLimits.maximumItemFactsPerRecord else {
            return .failure("history.archive.limitExceeded")
        }
        let facts = result.payload.items.map {
            HistoryItemFact(
                requestID: $0.requestID,
                intent: .permanent,
                disposition: $0.disposition,
                mutation: $0.mutation,
                affectedBytes: $0.freedBytes,
                receipt: nil)
        }
        return makeTypedCandidate(
            module: module,
            operation: result.outcome,
            facts: facts,
            reportedReclaimedBytes: result.payload.freedBytes,
            reportedRemovedCount: result.outcome.counts.succeeded,
            date: date)
    }

    private static func makeTypedCandidate(
        module: String,
        operation: OperationOutcome,
        facts: [HistoryItemFact],
        reportedReclaimedBytes: Int64,
        reportedRemovedCount: Int,
        date: Date
    ) -> HistoryCodeResult<ValidatedHistoryRecordCandidate> {
        guard module.utf8.count <= HistoryArchiveLimits.maximumModuleUTF8Bytes,
              operation.kind.rawValue.utf8.count
                <= HistoryArchiveLimits.maximumKindUTF8Bytes,
              facts.count <= HistoryArchiveLimits.maximumItemFactsPerRecord,
              operation.issues.count <= HistoryArchiveLimits.maximumIssuesPerOperation else {
            return .failure("history.archive.limitExceeded")
        }
        if containsPathMetadata(module)
            || containsPathMetadata(operation.kind.rawValue)
            || operation.issues.contains(where: issueContainsPathMetadata) {
            return .failure("history.privacy.pathMetadata")
        }
        let requestIDs = facts.map { $0.requestID.uuidString }
        guard Set(requestIDs).count == requestIDs.count,
              !requestIDs.isEmpty else {
            return .failure("history.operation.invalidFacts")
        }
        let requestSet = Set(requestIDs)
        let allIssues = operation.issues + facts.compactMap {
            switch $0.disposition {
            case let .skipped(issue), let .failed(issue): issue
            case let .cancelled(issue): issue
            case .succeeded, .unchanged: nil
            }
        }
        if allIssues.contains(where: {
            $0.code.utf8.count > HistoryArchiveLimits.maximumCodeUTF8Bytes
                || ($0.subjectID?.utf8.count ?? 0) > HistoryArchiveLimits.maximumSubjectUTF8Bytes
        }) {
            return .failure("history.archive.limitExceeded")
        }
        if allIssues.contains(where: issueContainsPathMetadata) {
            return .failure("history.privacy.pathMetadata")
        }
        if allIssues.contains(where: {
            guard let subject = $0.subjectID else { return false }
            return !requestSet.contains(subject)
        }) {
            return .failure("history.issue.unboundSubject")
        }
        for fact in facts {
            if fact.affectedBytes < 0
                || (fact.disposition != .succeeded && fact.affectedBytes != 0) {
                return .failure("history.operation.invalidFacts")
            }
            if let receipt = fact.receipt {
                guard HistoryReceiptValidation.isValid(receipt),
                      fact.intent == .trash,
                      fact.disposition == .succeeded,
                      fact.mutation == .changed else {
                    return .failure("history.receipt.invalidBinding")
                }
            }
        }
        let receipts = facts.compactMap(\.receipt)
        guard receiptsAreUnique(receipts) else {
            return .failure("history.receipt.invalidBinding")
        }
        let reduced: OperationOutcome
        do {
            reduced = try OperationOutcomeReducer.reduce(
                id: operation.id,
                parentID: operation.parentID,
                kind: operation.kind,
                requestedSubjectIDs: requestIDs,
                itemOutcomes: facts.map {
                    OperationItemOutcome(
                        subjectID: $0.requestID.uuidString,
                        disposition: $0.disposition,
                        mutation: $0.mutation,
                        affectedBytes: $0.affectedBytes)
                },
                cancellationAccepted: operation.status == .cancelled,
                startedAt: operation.startedAt,
                finishedAt: operation.finishedAt)
        } catch {
            return .failure("history.operation.invalidFacts")
        }
        guard reduced.id == operation.id,
              reduced.parentID == operation.parentID,
              reduced.kind == operation.kind,
              reduced.status == operation.status,
              reduced.counts == operation.counts,
              reduced.startedAt == operation.startedAt,
              reduced.finishedAt == operation.finishedAt,
              reduced.issues == operation.issues,
              reduced.mutation == operation.mutation,
              reportedRemovedCount == operation.counts.succeeded else {
            return .failure("history.operation.invalidFacts")
        }
        let reclaimed = facts.reduce(Int64(0)) { total, fact in
            guard fact.disposition == .succeeded else { return total }
            return saturatingAdd(total, fact.affectedBytes)
        }
        guard reclaimed == reportedReclaimedBytes else {
            return .failure("history.operation.invalidFacts")
        }
        let record = CleaningRecord(
            id: UUID(),
            date: date,
            module: module,
            reclaimedBytes: reclaimed,
            removedCount: operation.counts.succeeded,
            restorable: receipts,
            schemaVersion: 1,
            operationID: operation.id,
            parentOperationID: operation.parentID,
            operationKind: operation.kind,
            outcomeStatus: HistoryOutcomeStatus(operation.status),
            mutation: operation.mutation,
            counts: operation.counts,
            itemFacts: facts,
            startedAt: operation.startedAt,
            finishedAt: operation.finishedAt,
            issues: operation.issues,
            isTrustedForAggregates: true)
        return .success(ValidatedHistoryRecordCandidate(record: record))
    }

    private static func isRemoveOnlyReceiptUpdate(
        existing: [RestorableItem],
        requested: [RestorableItem]
    ) -> Bool {
        guard requested.allSatisfy(HistoryReceiptValidation.isValid),
              receiptsAreUnique(requested) else { return false }
        let existingSet = Set(existing.map(HistoryReceiptIdentity.init))
        let requestedSet = Set(requested.map(HistoryReceiptIdentity.init))
        return requestedSet.isSubset(of: existingSet)
    }

    private static func receiptsAreUnique(_ receipts: [RestorableItem]) -> Bool {
        var pairs = Set<HistoryReceiptIdentity>()
        var locations = Set<String>()
        for receipt in receipts {
            let identity = HistoryReceiptIdentity(receipt)
            guard pairs.insert(identity).inserted,
                  locations.insert(identity.original).inserted,
                  locations.insert(identity.trashed).inserted else { return false }
        }
        return true
    }

    private static func insertingWithRetention(
        _ record: CleaningRecord,
        into records: [CleaningRecord]
    ) -> [CleaningRecord]? {
        if records.count >= HistoryArchiveLimits.maximumRecords,
           let oldestDate = records.map(\.date).min(),
           record.date < oldestDate {
            return nil
        }

        var updated = records
        let insertionIndex = updated.firstIndex { existing in
            existing.date <= record.date
        } ?? updated.endIndex
        updated.insert(record, at: insertionIndex)
        guard updated.count > HistoryArchiveLimits.maximumRecords else { return updated }
        var oldestIndex = 0
        for index in updated.indices.dropFirst() {
            if updated[index].date < updated[oldestIndex].date
                || (updated[index].date == updated[oldestIndex].date && index > oldestIndex) {
                oldestIndex = index
            }
        }
        updated.remove(at: oldestIndex)
        return updated
    }

    private static func failureRequiresDegradation(_ code: String) -> Bool {
        code.contains("unsafe") || code.contains("IdentityChanged")
    }

    private static func issueContainsPathMetadata(_ issue: OperationIssue) -> Bool {
        containsPathMetadata(issue.code)
            || issue.subjectID.map(containsPathMetadata) == true
    }

    private static func containsPathMetadata(_ value: String) -> Bool {
        HistoryMetadataPrivacy.containsLocalPath(value)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? .max : sum
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Xico", isDirectory: true)
    }
}
