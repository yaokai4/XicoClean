import XCTest
import Darwin
@testable import Infrastructure
import Shared

final class ProcessAccuracyBenchmarkTests: XCTestCase {
    private var accuracyTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["XICO_RUN_PROCESS_ACCURACY"] == "1"
    }

    private func requireAccuracyTests() throws {
        try XCTSkipIf(
            !accuracyTestsEnabled,
            "Set XICO_RUN_PROCESS_ACCURACY=1 to run real-machine process accuracy checks."
        )
    }

    func testPIDEnumerationTracksKernelCountWithinChurnAllowance() throws {
        try requireAccuracyTests()

        let kernelCount = max(0, Int(proc_listallpids(nil, 0)))
        let enumeratedCount = PIDEnumerator().allPIDs().count

        print("ACCURACY_RESULT pid_enumerated=\(enumeratedCount) kernel_count=\(kernelCount) allowance=32")
        XCTAssertGreaterThanOrEqual(enumeratedCount, kernelCount - 32)
    }

    func testCurrentProcessFootprintMatchesTopWithinFivePercent() throws {
        try requireAccuracyTests()

        let pid = getpid()
        let topOutput = try runTop(pid: pid)
        guard let topBytes = Self.latestTopMemoryBytes(output: topOutput, pid: pid) else {
            XCTFail("Could not parse current process memory from top output:\n\(topOutput)")
            return
        }
        let record = try readRecord(pid: pid)
        let footprint = record.physicalFootprintBytes
        XCTAssertGreaterThan(footprint, 0)
        let relativeDifference = abs(Double(topBytes - footprint)) / Double(max(1, footprint))

        print(
            "ACCURACY_RESULT memory_pid=\(pid) top_bytes=\(topBytes) "
                + "phys_footprint_bytes=\(footprint) relative_difference=\(relativeDifference)"
        )
        XCTAssertLessThanOrEqual(relativeDifference, 0.05)
    }

    func testYesRawCPUAndNormalizedFormula() throws {
        try requireAccuracyTests()

        let process = Process()
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.standardOutput = nullOutput
        process.standardError = nullOutput
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        Thread.sleep(forTimeInterval: 0.1)
        let firstRecord = try readRecord(pid: process.processIdentifier)
        let firstTime = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 1.0)
        let secondRecord = try readRecord(pid: process.processIdentifier)
        let secondTime = DispatchTime.now().uptimeNanoseconds

        var calculator = ProcessCPUDeltaCalculator()
        _ = calculator.rates(for: capture(record: firstRecord, time: firstTime))
        let rates = try XCTUnwrap(calculator.rates(for: capture(record: secondRecord, time: secondTime)))
        let identity = ProcessIdentity(
            pid: secondRecord.pid,
            startTimeNanoseconds: secondRecord.startTimeNanoseconds
        )
        let rawCPU = try XCTUnwrap(rates[identity])
        let logicalCPUCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let ownership = ApplicationOwnershipResolver().resolve([secondRecord])
        let usage = try XCTUnwrap(ApplicationUsageAggregator(logicalCPUCount: logicalCPUCount).aggregate(
            records: [secondRecord],
            ownership: ownership,
            cpuRawByProcess: rates,
            combinesProcesses: true
        ).first)
        let normalizedCPU = try XCTUnwrap(usage.cpuNormalizedPercent)
        let expectedNormalized = rawCPU / Double(logicalCPUCount)

        print(
            "ACCURACY_RESULT yes_pid=\(process.processIdentifier) raw_cpu=\(rawCPU) "
                + "normalized_cpu=\(normalizedCPU) logical_cpus=\(logicalCPUCount) "
                + "cpu_start_ns=\(firstRecord.cpuTimeNanoseconds) cpu_end_ns=\(secondRecord.cpuTimeNanoseconds) "
                + "elapsed_ns=\(secondTime - firstTime) running=\(process.isRunning)"
        )
        XCTAssertGreaterThanOrEqual(rawCPU, 70)
        XCTAssertLessThanOrEqual(rawCPU, 130)
        XCTAssertEqual(normalizedCPU, expectedNormalized, accuracy: 0.5)
    }

    func testStableApplicationGroupsMatchTopAndMemberTotals() async throws {
        try requireAccuracyTests()

        let provider = LocalProcessSnapshotProvider()
        let first = await provider.capture()
        try await Task.sleep(for: .seconds(1))
        let second = await provider.capture()
        var cpu = ProcessCPUDeltaCalculator()
        _ = cpu.rates(for: first)
        let rates = try XCTUnwrap(cpu.rates(for: second))
        let ownership = ApplicationOwnershipResolver().resolve(second.records)
        let usages = ApplicationUsageAggregator(
            logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount
        ).aggregate(
            records: second.records,
            ownership: ownership,
            cpuRawByProcess: rates,
            combinesProcesses: true,
            sortsByCPU: false)
        let recordsByIdentity = Dictionary(
            uniqueKeysWithValues: second.records.map {
                (ProcessIdentity(pid: $0.pid, startTimeNanoseconds: $0.startTimeNanoseconds), $0)
            })

        let xico = usages.first { usage in
            usage.bundleIdentifier == "com.xico.app" || usage.displayName == "Xico"
        }
        let interactive = usages.first { usage in
            let path = usage.bundlePath ?? ""
            return path.contains("/ChatGPT.app")
                || path.contains("/Codex.app")
                || path.contains("/Google Chrome.app")
        }
        let daemon = usages.first { usage in
            usage.bundlePath == nil && usage.members.contains { member in
                guard let path = recordsByIdentity[member.identity]?.executablePath else { return false }
                return path.hasPrefix("/usr/libexec/") || path.hasPrefix("/System/Library/")
            }
        }
        let categories = [
            ("xico", try XCTUnwrap(xico, "Launch ~/Applications/Xico.app before this audit")),
            ("interactive", try XCTUnwrap(interactive, "No running ChatGPT/Codex/Chrome group found")),
            ("daemon", try XCTUnwrap(daemon, "No readable stable system daemon found")),
        ]
        let topOutput = try runTopForAllProcesses()
        let logicalCPUs = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

        for (category, usage) in categories {
            let memberMemory = usage.members.reduce(Int64(0)) { $0 + $1.physicalFootprintBytes }
            let memberCPU = usage.members.compactMap(\.cpuRawPercent).reduce(0, +)
            XCTAssertEqual(memberMemory, usage.physicalFootprintBytes)
            XCTAssertEqual(memberCPU, usage.cpuRawPercent ?? 0, accuracy: 0.001)
            if let rawCPU = usage.cpuRawPercent, let normalizedCPU = usage.cpuNormalizedPercent {
                XCTAssertEqual(normalizedCPU, rawCPU / logicalCPUs, accuracy: 0.001)
            }

            let topValues = usage.members.compactMap { member in
                Self.latestTopMemoryBytes(output: topOutput, pid: member.identity.pid)
            }
            let topMemory = topValues.reduce(Int64(0), +)
            let relativeDifference = abs(Double(topMemory - memberMemory)) / Double(max(1, memberMemory))
            print(
                "ACCURACY_RESULT category=\(category) name=\(usage.displayName) "
                    + "members=\(usage.memberCount) top_members=\(topValues.count) "
                    + "top_bytes=\(topMemory) footprint_bytes=\(memberMemory) "
                    + "relative_difference=\(relativeDifference) raw_cpu=\(usage.cpuRawPercent ?? -1) "
                    + "normalized_cpu=\(usage.cpuNormalizedPercent ?? -1)"
            )
            XCTAssertEqual(topValues.count, usage.memberCount)
            XCTAssertLessThanOrEqual(relativeDifference, 0.20)
        }
    }

    func testAggregationPreservesTwelveHundredMembersAndExactTotals() throws {
        try requireAccuracyTests()

        var records: [ProcessResourceRecord] = []
        records.reserveCapacity(1_200)
        for index in 0..<1_200 {
            let ordinal = index + 1
            records.append(ProcessResourceRecord(
                pid: Int32(10_000 + index),
                parentPID: 1,
                startTimeNanoseconds: UInt64(ordinal),
                name: "fixture-\(index)",
                executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
                cpuTimeNanoseconds: UInt64(ordinal) * 1_000_000,
                physicalFootprintBytes: Int64(ordinal) * 4_096,
                peakFootprintBytes: Int64(ordinal) * 8_192
            ))
        }
        let ownership = ApplicationOwnershipResolver().resolve(records)
        var cpuByProcess: [ProcessIdentity: Double] = [:]
        cpuByProcess.reserveCapacity(records.count)
        for record in records {
            let identity = ProcessIdentity(
                pid: record.pid,
                startTimeNanoseconds: record.startTimeNanoseconds
            )
            cpuByProcess[identity] = Double(Int(record.pid) % 17)
        }
        let expectedCPU = cpuByProcess.values.reduce(0, +)
        let expectedFootprint = records.reduce(Int64(0)) { $0 + $1.physicalFootprintBytes }
        let usage = try XCTUnwrap(ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: records,
            ownership: ownership,
            cpuRawByProcess: cpuByProcess,
            combinesProcesses: true
        ).first)

        print(
            "ACCURACY_RESULT aggregate_records=\(records.count) members=\(usage.memberCount) "
                + "cpu_total=\(usage.cpuRawPercent ?? -1) footprint_bytes=\(usage.physicalFootprintBytes)"
        )
        XCTAssertEqual(usage.memberCount, records.count)
        XCTAssertEqual(usage.cpuRawPercent, expectedCPU)
        XCTAssertEqual(usage.physicalFootprintBytes, expectedFootprint)
    }

    func testLocalCaptureP95IsUnderFifteenMilliseconds() async throws {
        try requireAccuracyTests()

        let provider = LocalProcessSnapshotProvider()
        var durationsMilliseconds: [Double] = []
        durationsMilliseconds.reserveCapacity(20)
        var latestCount = 0
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let capture = await provider.capture()
            let end = DispatchTime.now().uptimeNanoseconds
            durationsMilliseconds.append(Double(end - start) / 1_000_000)
            latestCount = capture.records.count
        }
        let sorted = durationsMilliseconds.sorted()
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95 = sorted[p95Index]

        print(
            "ACCURACY_RESULT capture_samples=\(sorted.count) p95_ms=\(p95) "
                + "min_ms=\(sorted.first ?? -1) max_ms=\(sorted.last ?? -1) records=\(latestCount)"
        )
        XCTAssertLessThan(p95, 15)
    }

    func testApplicationSamplingMeetsRuntimeBudgets() async throws {
        try requireAccuracyTests()

        let interval: TimeInterval = 1
        let sampleCount = 60
        let sampler = ProcessSampler(
            provider: LocalProcessSnapshotProvider(),
            logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount
        )
        await sampler.prewarm()

        let openedAt = CFAbsoluteTimeGetCurrent()
        let warming = await sampler.sample(limit: 6)
        let memoryRowsMilliseconds = warming.byMemory.isEmpty
            ? .infinity
            : (CFAbsoluteTimeGetCurrent() - openedAt) * 1_000
        let firstTickElapsed = CFAbsoluteTimeGetCurrent() - openedAt
        try await Task.sleep(for: .seconds(max(0, interval - firstTickElapsed)))
        let live = await sampler.sample(limit: 6)
        let cpuRowsSeconds = live.byCPU.isEmpty
            ? .infinity
            : CFAbsoluteTimeGetCurrent() - openedAt

        let footprintStart = Self.processPhysicalFootprint()
        let cpuStart = Self.processCPUSeconds()
        let wallStart = CFAbsoluteTimeGetCurrent()
        for index in 0..<sampleCount {
            let tickStart = CFAbsoluteTimeGetCurrent()
            _ = await sampler.sample(limit: 6)
            if index + 1 < sampleCount {
                let tickElapsed = CFAbsoluteTimeGetCurrent() - tickStart
                try await Task.sleep(for: .seconds(max(0, interval - tickElapsed)))
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - wallStart
        let cpuPercent = max(0, Self.processCPUSeconds() - cpuStart) / elapsed * 100
        let footprintEnd = Self.processPhysicalFootprint()
        let footprintDelta = max(0, Int64(clamping: footprintEnd) - Int64(clamping: footprintStart))

        print(
            "ACCURACY_RESULT application_samples=\(sampleCount) duration=\(elapsed) "
                + "cpu_percent=\(cpuPercent) footprint_start=\(footprintStart) "
                + "footprint_end=\(footprintEnd) footprint_delta=\(footprintDelta) "
                + "memory_rows_ms=\(memoryRowsMilliseconds) cpu_rows_s=\(cpuRowsSeconds) "
                + "sampled=\(live.coverage.sampled) denied=\(live.coverage.denied)"
        )
        XCTAssertLessThan(cpuPercent, 1.5)
        XCTAssertLessThan(footprintDelta, 12 * 1_024 * 1_024)
        XCTAssertLessThan(memoryRowsMilliseconds, 150)
        XCTAssertLessThanOrEqual(cpuRowsSeconds, interval + 0.25)
    }

    @MainActor
    func testDelayedHelperDoesNotBlockFirstLocalCapture() async throws {
        try requireAccuracyTests()

        let record = try readRecord(pid: getpid())
        let local = FixedCaptureProvider(capture: ProcessCapture(
            records: [record],
            failures: [Int32.max: .permissionDenied],
            wallDate: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            source: .local,
            enumeratedCount: 2
        ))
        let provider = HybridProcessSnapshotProvider(
            local: local,
            helper: DelayedProcessHelper(delay: .seconds(1)),
            helperRetryDelay: 60
        )
        let started = CFAbsoluteTimeGetCurrent()
        let capture = await provider.capture()
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000

        print(
            "ACCURACY_RESULT helper_first_capture_ms=\(elapsedMilliseconds) "
                + "source=\(capture.source.rawValue) records=\(capture.records.count)"
        )
        XCTAssertLessThan(elapsedMilliseconds, 150)
        XCTAssertEqual(capture.source, .local)
        XCTAssertEqual(capture.records.map(\.pid), [record.pid])
    }

    private func readRecord(pid: Int32) throws -> ProcessResourceRecord {
        switch DarwinProcessResourceReader.read(pid: pid) {
        case .success(let record):
            return record
        case .failure(let failure):
            XCTFail("Could not read process \(pid): \(failure.rawValue)")
            throw failure
        }
    }

    private func runTop(pid: Int32) throws -> String {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-pid", String(pid), "-stats", "pid,mem"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TopError.failed(
                status: process.terminationStatus,
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    private func runTopForAllProcesses() throws -> String {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-n", "1000", "-stats", "pid,mem"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw TopError.failed(
                status: process.terminationStatus,
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    private func capture(record: ProcessResourceRecord, time: UInt64) -> ProcessCapture {
        ProcessCapture(
            records: [record],
            failures: [:],
            wallDate: Date(),
            monotonicNanoseconds: time,
            source: .local,
            enumeratedCount: 1
        )
    }

    private static func latestTopMemoryBytes(output: String, pid: Int32) -> Int64? {
        output.split(whereSeparator: \Character.isNewline).compactMap { line -> Int64? in
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 2, Int32(columns[0]) == pid else { return nil }
            return topMemoryBytes(token: String(columns[1]))
        }.last
    }

    private static func topMemoryBytes(token: String) -> Int64? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard !trimmed.isEmpty else { return nil }

        let unitCharacter = trimmed.last.map { Character(String($0).uppercased()) }
        let multiplier: Double
        let number: Substring
        switch unitCharacter {
        case "B":
            multiplier = 1
            number = trimmed.dropLast()
        case "K":
            multiplier = 1_024
            number = trimmed.dropLast()
        case "M":
            multiplier = 1_024 * 1_024
            number = trimmed.dropLast()
        case "G":
            multiplier = 1_024 * 1_024 * 1_024
            number = trimmed.dropLast()
        case "T":
            multiplier = 1_024 * 1_024 * 1_024 * 1_024
            number = trimmed.dropLast()
        default:
            multiplier = 1
            number = trimmed[...]
        }
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        return Int64((value * multiplier).rounded())
    }

    private static func processCPUSeconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    private static func processPhysicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

private struct FixedCaptureProvider: ProcessSnapshotProviding {
    let captureValue: ProcessCapture

    init(capture: ProcessCapture) {
        captureValue = capture
    }

    func capture() async -> ProcessCapture { captureValue }
}

private struct DelayedProcessHelper: PrivilegedProcessSampling {
    let delay: Duration
    var processSamplingAvailable: Bool { true }

    func sampleProcesses(pids: [Int32]) async -> ProcessHelperBatchResponse? {
        try? await Task.sleep(for: delay)
        return nil
    }
}

private enum TopError: Error {
    case failed(status: Int32, stderr: String)
}
