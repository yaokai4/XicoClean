# Task 1 Report: Correct Full-PID Capture and Shared libproc Records

## Implementation summary

- Added the shared, Codable process resource record and helper batch response.
- Added errno-based process read failure classification and a Darwin reader backed by `proc_pidinfo(PROC_PIDTBSDINFO)`, `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_pidpath`, and `proc_name`.
- Added process identity/capture models and the snapshot provider protocols.
- Added a count-correct `proc_listallpids` adapter and a bounded, resizing PID enumerator that filters invalid PIDs, removes duplicates, and returns sorted results.
- Added `LocalProcessSnapshotProvider`, which enumerates once, reads every enumerated PID, records each PID's failure category, and records wall and monotonic capture clocks.
- Preserved safe, length-bounded UTF-8 decoding with `String(decoding:as:)` for paths and process names.

Commit: `9c9527f fix: capture every visible process`

## Files changed

- `Sources/Shared/ProcessResourceRecord.swift`
- `Sources/Infrastructure/ApplicationUsageModels.swift`
- `Sources/Infrastructure/ProcessSnapshotProvider.swift`
- `Tests/IntegrationTests/ProcessSnapshotProviderTests.swift`

The commit contains only these four files.

## RED

Command:

```text
swift test --filter ProcessSnapshotProviderTests
```

Observed output (expected excerpts):

```text
error: cannot find type 'PIDListing' in scope
error: cannot find 'PIDEnumerator' in scope
error: cannot find 'ProcessIdentity' in scope
error: fatalError
```

Expected reason: the test was added first and referenced the new PID-listing, PID-enumerator, and process-identity interfaces before any production implementation existed. The nonzero compiler result therefore demonstrated the intended missing-interface failure.

## GREEN

Fresh final command after implementation and the final import cleanup:

```text
swift test --filter ProcessSnapshotProviderTests && swift test --filter MonitoringTests
```

Observed output (relevant summary):

```text
Test Suite 'ProcessSnapshotProviderTests' passed.
Executed 3 tests, with 0 failures (0 unexpected)

Test Suite 'MonitoringTests' passed.
Executed 9 tests, with 0 failures (0 unexpected)
```

Both commands exited successfully. The fresh run rebuilt the affected modules and exercised 12 selected XCTest cases with zero failures.

## Self-review

- Confirmed `PIDListing.fill` and `PIDEnumerator` treat `proc_listallpids`'s return value as a PID count, not a byte count.
- Confirmed a full buffer triggers growth and retry, while the non-full result uses exactly `buffer.prefix(count)`.
- Confirmed PID results exclude nonpositive values, are deduplicated, and are sorted.
- Confirmed `ProcessIdentity` equality/hash identity includes both PID and start time.
- Confirmed `LocalProcessSnapshotProvider.capture()` calls the enumerator once, attempts every returned PID once, retains all successes, classifies failures by PID, and reports the original enumerated count.
- Confirmed the Darwin reader captures parent PID, nanosecond start time, combined user/system CPU time, current and lifetime peak physical footprint, executable path, and fallback process name.
- Confirmed path/name decoding remains safe for malformed UTF-8 and is bounded by the returned C API lengths.
- Ran `git diff --cached --check` before commit; it reported no whitespace errors.
- Inspected the complete staged diff and confirmed no unrelated pre-existing user changes were staged or committed.

## Concerns

No unresolved concerns.

Two compatibility adjustments were necessary for the active Swift 6/Xcode 26.5 toolchain:

- The SDK declares `PROC_PIDPATHINFO_MAXSIZE` as `4 * MAXPATHLEN` but marks that macro unavailable to Swift, so the implementation uses the identical `Int(MAXPATHLEN) * 4` value.
- Swift does not expose a public synthesized initializer for `DarwinPIDListing`; an explicit `public init() {}` is required because it appears in the public default argument of `PIDEnumerator.init`.

Both adjustments preserve the specified behavior and were covered by the final successful build/test run.
