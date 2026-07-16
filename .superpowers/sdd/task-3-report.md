# Task 3 Report: Helper Process Sampling

## Status

Implemented bounded, read-only privileged process sampling and local-first hybrid enrichment.

## RED evidence

Command:

```text
swift test --filter HelperProcessSamplingTests
```

Exit: `1`

Relevant output:

```text
error: cannot find type 'PrivilegedProcessSampling' in scope
error: cannot find 'HybridProcessSnapshotProvider' in scope
error: fatalError
```

The new merge tests failed for the expected reason: the helper sampling protocol and hybrid provider were absent.

## GREEN evidence

Command:

```text
swift test --filter HelperProcessSamplingTests && swift test --filter HelperFileRemoverTests && swift test --filter ApplicationUsageAggregatorTests
```

Exit: `0`

Relevant output:

```text
HelperProcessSamplingTests: Executed 2 tests, with 0 failures
HelperFileRemoverTests: Executed 7 tests, with 0 failures
ApplicationUsageAggregatorTests: Executed 15 tests, with 0 failures
```

`git diff --check` also completed with no whitespace errors for the six Task 3 files.

## Files

- `Sources/Shared/HelperProtocol.swift`
- `Sources/Shared/HelperSecurity.swift`
- `Sources/XicoHelper/main.swift`
- `Sources/Infrastructure/HelperProxy.swift`
- `Sources/Infrastructure/ProcessSnapshotProvider.swift`
- `Tests/IntegrationTests/HelperProcessSamplingTests.swift`

## Security self-review

- Preserved the existing client-to-helper and helper-to-client code-signing requirements; the new client method reuses `pinHelper` before resuming its fresh privileged connection.
- Bounded both ends at 4,096 PIDs. Oversized helper requests return `nil`; oversized client requests do not open a connection.
- Wrapped helper reads in the existing idle-exit operation accounting, so the daemon cannot exit mid-batch.
- Validated numeric PID range before calling `DarwinProcessResourceReader.read(pid:)`.
- Serialized only `ProcessHelperBatchResponse`, whose payload is `[ProcessResourceRecord]`. The endpoint does not read or return command lines, arguments, environment variables, file contents, or user content.
- Fixed the client timeout at 1.5 seconds and used `ResumeGuard`, preserving one-shot continuation behavior on reply, error, or timeout.
- Kept local capture unchanged on helper absence, timeout, decode failure, empty records, oversized batches, or records outside the requested permission-denied PID set.
- Merged recovered records by process identity `(pid, startTimeNanoseconds)`, removed only recovered PID failures, and preserved local timestamps and enumeration count.
- Left protected-file deletion and maintenance behavior unchanged.

## Concerns

- The package test environment builds the helper but does not install/sign it as a privileged launch daemon, so a live signed XPC round-trip was not exercised. Protocol compilation, client fallback behavior, merge behavior, deletion safety, and aggregation regressions are covered.
