import Foundation

/// Records consumed one-time authorization nonces. The `actor` makes consumption
/// atomic: `consume` returns `true` only the first time a given nonce is seen, so a
/// nonce can drive at most one destructive execution even under concurrent attempts.
public actor AuthorizationLedger {
    private var consumed: Set<UUID> = []

    public init() {}

    /// Atomically inserts `nonce`; returns `true` only on first insertion.
    public func consume(_ nonce: UUID) -> Bool {
        consumed.insert(nonce).inserted
    }
}
