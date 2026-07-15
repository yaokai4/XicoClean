import XCTest
@testable import Infrastructure
import Shared

final class ApplicationUsageAggregatorTests: XCTestCase {
    private func record(pid: Int32, parent: Int32 = 1, start: UInt64 = 1,
                        path: String?, cpu: UInt64, memory: Int64) -> ProcessResourceRecord {
        ProcessResourceRecord(pid: pid, parentPID: parent, startTimeNanoseconds: start,
                              name: "p\(pid)", executablePath: path,
                              cpuTimeNanoseconds: cpu, physicalFootprintBytes: memory,
                              peakFootprintBytes: memory)
    }

    func testChromeHelperUsesOutermostApplicationBundle() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertEqual(ApplicationOwnershipResolver.outermostApplicationPath(in: path),
                       "/Applications/Google Chrome.app")
    }

    func testBundleMetadataUsesPreferredLocalizedDisplayName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let application = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let localization = contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localization,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.localized",
            "CFBundleName": "Fixture English",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en", "zh-Hans"],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        let localizedData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleDisplayName": "本地化名称"],
            format: .xml,
            options: 0
        )
        try localizedData.write(to: localization.appendingPathComponent("InfoPlist.strings"))

        let metadata = BundleApplicationMetadataProvider(
            preferredLanguages: { ["zh-Hans"] }
        ).metadata(forApplicationAt: application.path)

        XCTAssertEqual(metadata.bundleIdentifier, "com.example.localized")
        XCTAssertEqual(metadata.displayName, "本地化名称")
    }

    func testBundleMetadataAndParentChainDefineApplicationOwnership() {
        let applicationPath = "/Applications/Demo.app"
        let records = [
            record(pid: 10, path: "\(applicationPath)/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: "/usr/bin/demo-helper",
                   cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let metadata = ApplicationMetadata(
            bundleIdentifier: "com.example.demo",
            displayName: "Demo Display Name"
        )
        let ownership = ApplicationOwnershipResolver(metadataProvider: DictionaryMetadataProvider(
            metadataByPath: [applicationPath: metadata]
        )).resolve(records)
        let root = ownership[ProcessIdentity(pid: 10, startTimeNanoseconds: 1)]
        let child = ownership[ProcessIdentity(pid: 11, startTimeNanoseconds: 1)]

        XCTAssertEqual(root?.identity.rawValue, "bundle:com.example.demo")
        XCTAssertEqual(root?.displayName, "Demo Display Name")
        XCTAssertEqual(root?.bundlePath, applicationPath)
        XCTAssertEqual(child, root)
    }

    func testApplicationMetadataIsReadOncePerBundlePath() {
        let applicationPath = "/Applications/Fixture.app"
        let records = (0..<1_200).map { index in
            record(
                pid: Int32(10_000 + index),
                path: "\(applicationPath)/Contents/Frameworks/worker-\(index)",
                cpu: UInt64(index),
                memory: Int64(index)
            )
        }
        let provider = CountingMetadataProvider(metadata: ApplicationMetadata(
            bundleIdentifier: "com.example.fixture",
            displayName: "Fixture"
        ))

        let resolver = ApplicationOwnershipResolver(metadataProvider: provider)
        let ownership = resolver.resolve(records)
        let nextFrameOwnership = resolver.resolve(records)

        XCTAssertEqual(ownership.count, records.count)
        XCTAssertEqual(nextFrameOwnership.count, records.count)
        XCTAssertEqual(provider.invocationCount, 1)
    }

    func testResolvedBundleOwnershipIsReusedForTheSameProcessIdentity() {
        let pathResolver = CountingApplicationPathResolver()
        let resolver = ApplicationOwnershipResolver(
            metadataProvider: DictionaryMetadataProvider(metadataByPath: [:]),
            applicationPathResolver: { pathResolver.resolve($0) }
        )
        let process = record(
            pid: 10,
            start: 7,
            path: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            cpu: 1,
            memory: 1
        )

        _ = resolver.resolve([process])
        let secondFrame = resolver.resolve([process])

        XCTAssertEqual(pathResolver.invocationCount, 1)
        XCTAssertEqual(resolver.cacheMissCount, 1)
        XCTAssertEqual(
            secondFrame[ProcessIdentity(pid: 10, startTimeNanoseconds: 7)]?.bundlePath,
            "/Applications/Fixture.app"
        )
    }

    func testReusedPIDWithNewStartTimeRecomputesOwnership() {
        let pathResolver = CountingApplicationPathResolver()
        let resolver = ApplicationOwnershipResolver(
            metadataProvider: DictionaryMetadataProvider(metadataByPath: [:]),
            applicationPathResolver: { pathResolver.resolve($0) }
        )
        let first = record(
            pid: 10,
            start: 7,
            path: "/Applications/First.app/Contents/MacOS/First",
            cpu: 1,
            memory: 1
        )
        let reused = record(
            pid: 10,
            start: 8,
            path: "/Applications/Second.app/Contents/MacOS/Second",
            cpu: 1,
            memory: 1
        )

        let firstFrame = resolver.resolve([first])
        let secondFrame = resolver.resolve([reused])

        XCTAssertEqual(pathResolver.invocationCount, 2)
        XCTAssertEqual(
            firstFrame[ProcessIdentity(pid: 10, startTimeNanoseconds: 7)]?.bundlePath,
            "/Applications/First.app"
        )
        XCTAssertEqual(
            secondFrame[ProcessIdentity(pid: 10, startTimeNanoseconds: 8)]?.bundlePath,
            "/Applications/Second.app"
        )
    }

    func testFallbackOwnershipCanBeCorrectedWhenParentApplicationAppears() {
        let resolver = ApplicationOwnershipResolver()
        let child = record(
            pid: 11,
            parent: 10,
            start: 7,
            path: "/usr/bin/fixture-worker",
            cpu: 1,
            memory: 1
        )
        let initial = resolver.resolve([child])
        XCTAssertNil(initial[ProcessIdentity(pid: 11, startTimeNanoseconds: 7)]?.bundlePath)

        let parent = record(
            pid: 10,
            start: 3,
            path: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            cpu: 1,
            memory: 1
        )
        let corrected = resolver.resolve([parent, child])

        XCTAssertEqual(
            corrected[ProcessIdentity(pid: 11, startTimeNanoseconds: 7)]?.bundlePath,
            "/Applications/Fixture.app"
        )
    }

    func testCompleteLaunchdFallbackOwnershipIsReusedAcrossFrames() {
        let pathResolver = CountingApplicationPathResolver()
        let resolver = ApplicationOwnershipResolver(
            metadataProvider: DictionaryMetadataProvider(metadataByPath: [:]),
            applicationPathResolver: { pathResolver.resolve($0) }
        )
        let daemon = record(
            pid: 42,
            parent: 1,
            start: 7,
            path: "/usr/libexec/fixture-daemon",
            cpu: 1,
            memory: 1
        )

        _ = resolver.resolve([daemon])
        _ = resolver.resolve([daemon])

        XCTAssertEqual(pathResolver.invocationCount, 1)
    }

    func testApplicationAggregationSumsMembers() {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo", cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: nil, cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let ownership = ApplicationOwnershipResolver().resolve(records)
        let usage = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: records, ownership: ownership,
            cpuRawByProcess: [ProcessIdentity(pid: 10, startTimeNanoseconds: 1): 80,
                              ProcessIdentity(pid: 11, startTimeNanoseconds: 1): 40],
            combinesProcesses: true).first!
        XCTAssertEqual(usage.memberCount, 2)
        XCTAssertEqual(usage.physicalFootprintBytes, 600_000_000)
        XCTAssertEqual(usage.cpuRawPercent!, 120, accuracy: 0.001)
        XCTAssertEqual(usage.cpuNormalizedPercent!, 15, accuracy: 0.001)
    }

    func testFirstSampleAndLongGapWarmUpInsteadOfZero() {
        var calculator = ProcessCPUDeltaCalculator(maximumIntervalNanoseconds: 10_000_000_000)
        let first = ProcessCapture.fixture(time: 1_000_000_000, cpu: 1_000_000_000, start: 1)
        let second = ProcessCapture.fixture(time: 2_000_000_000, cpu: 2_000_000_000, start: 1)
        let late = ProcessCapture.fixture(time: 30_000_000_000, cpu: 3_000_000_000, start: 1)
        let afterLate = ProcessCapture.fixture(time: 31_000_000_000, cpu: 4_000_000_000, start: 1)
        XCTAssertNil(calculator.rates(for: first))
        XCTAssertEqual(calculator.rates(for: second)?.values.first ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertNil(calculator.rates(for: late))
        XCTAssertEqual(calculator.rates(for: afterLate)?.values.first ?? -.infinity,
                       100, accuracy: 0.001)
    }

    func testReusedPIDDoesNotInheritCPUTime() {
        var calculator = ProcessCPUDeltaCalculator()
        _ = calculator.rates(for: .fixture(time: 1_000_000_000, cpu: 1_000_000_000, start: 1))
        let reused = calculator.rates(for: .fixture(time: 2_000_000_000, cpu: 9_000_000_000, start: 2))
        XCTAssertTrue(reused?.isEmpty == true)
    }

    func testStableRankingKeepsPreviousOrderInsideThreePercentBand() {
        let a = ApplicationUsage.fixture(id: "a", rawCPU: 50, memory: 100)
        let b = ApplicationUsage.fixture(id: "b", rawCPU: 49, memory: 99)
        let ordered = UsageRanker.order([b, a], metric: .cpu, previousOrder: [b.id, a.id])
        XCTAssertEqual(ordered.map(\.id), [b.id, a.id])
    }

    func testStableRankingCycleProducesDeterministicStrictOrder() {
        let a = ApplicationUsage.fixture(id: "a", rawCPU: 100, memory: 100)
        let b = ApplicationUsage.fixture(id: "b", rawCPU: 98, memory: 98)
        let c = ApplicationUsage.fixture(id: "c", rawCPU: 96, memory: 96)
        let previousOrder = [c.id, b.id, a.id]
        let expectedOrder = [b.id, a.id, c.id]
        let permutations = [
            [a, b, c], [a, c, b], [b, a, c],
            [b, c, a], [c, a, b], [c, b, a]
        ]

        for _ in 0..<5 {
            for input in permutations {
                let ordered = UsageRanker.order(
                    input,
                    metric: .cpu,
                    previousOrder: previousOrder
                )
                XCTAssertEqual(ordered.map(\.id), expectedOrder)
                XCTAssertLessThan(
                    ordered.firstIndex(where: { $0.id == a.id })!,
                    ordered.firstIndex(where: { $0.id == c.id })!
                )
            }
        }
    }

    func testBoundedRankingMatchesExactPrefixAndKeepsDistantHighValue() {
        var usages = (0..<240).map { index in
            ApplicationUsage.fixture(
                id: String(format: "ordinary-%03d", index),
                rawCPU: Double(index % 60),
                memory: Int64(10_000 + index)
            )
        }
        let distantHighValue = ApplicationUsage.fixture(
            id: "distant-high-value",
            rawCPU: 10_000,
            memory: 1
        )
        usages.append(distantHighValue)
        let previousOrder = usages.reversed().map(\.id)

        let exact = UsageRanker.order(
            usages,
            metric: .cpu,
            previousOrder: previousOrder
        )
        let bounded = UsageRanker.order(
            usages,
            metric: .cpu,
            previousOrder: previousOrder,
            limit: 20
        )

        XCTAssertEqual(bounded.map(\.id), Array(exact.prefix(20)).map(\.id))
        XCTAssertEqual(bounded.first?.id, distantHighValue.id)
    }

    func testBoundedRankingPreservesFiniteNaNAndNilExactPrefix() {
        let finite = ApplicationUsage.fixture(id: "finite", rawCPU: 42, memory: 3)
        let nan = ApplicationUsage.fixture(id: "nan", rawCPU: .nan, memory: 2)
        let missing = ApplicationUsage.fixture(id: "missing", rawCPU: nil, memory: 1)
        let usages = [finite, nan, missing]
        let previousOrder = [finite.id, missing.id, nan.id]

        let exact = UsageRanker.order(
            usages,
            metric: .cpu,
            previousOrder: previousOrder
        )
        let bounded = UsageRanker.order(
            usages,
            metric: .cpu,
            previousOrder: previousOrder,
            limit: 2
        )

        XCTAssertEqual(exact.map(\.id), [finite.id, nan.id, missing.id])
        XCTAssertEqual(bounded.map(\.id), Array(exact.prefix(2)).map(\.id))
    }

    func testCombineProcessesDisabledKeepsMembersSeparate() {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 400_000_000),
            record(pid: 11, parent: 10, path: nil,
                   cpu: 1_000_000_000, memory: 200_000_000)
        ]
        let ownership = ApplicationOwnershipResolver().resolve(records)
        let usages = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: records,
            ownership: ownership,
            cpuRawByProcess: [:],
            combinesProcesses: false
        )

        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(Set(usages.map(\.memberCount)), [1])
    }

    func testRepresentativeRootAndMemberHierarchyOrderAreDeterministic() {
        let root = record(pid: 30, parent: 1,
                          path: "/Applications/Demo.app/Contents/MacOS/Demo",
                          cpu: 3_000_000_000, memory: 300_000_000)
        let child = record(pid: 20, parent: 30, path: nil,
                           cpu: 2_000_000_000, memory: 200_000_000)
        let grandchild = record(pid: 10, parent: 20, path: nil,
                                cpu: 1_000_000_000, memory: 100_000_000)
        let permutations = [
            [root, child, grandchild], [root, grandchild, child],
            [child, root, grandchild], [child, grandchild, root],
            [grandchild, root, child], [grandchild, child, root]
        ]

        for records in permutations {
            let ownership = ApplicationOwnershipResolver().resolve(records)
            let usage = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
                records: records,
                ownership: ownership,
                cpuRawByProcess: [:],
                combinesProcesses: true
            ).first!

            XCTAssertEqual(usage.representativePID, 30)
            XCTAssertEqual(usage.members.map { $0.identity.pid }, [30, 20, 10])
        }
    }

    func testCyclicMemberHierarchyFallsBackToDeterministicPIDOrder() {
        let first = record(
            pid: 10,
            parent: 11,
            path: "/Applications/Demo.app/Contents/MacOS/first",
            cpu: 1,
            memory: 1
        )
        let second = record(
            pid: 11,
            parent: 10,
            path: "/Applications/Demo.app/Contents/MacOS/second",
            cpu: 1,
            memory: 1
        )
        let ownership = ApplicationOwnershipResolver().resolve([second, first])

        let usage = ApplicationUsageAggregator(logicalCPUCount: 8).aggregate(
            records: [second, first],
            ownership: ownership,
            cpuRawByProcess: [:],
            combinesProcesses: true
        ).first!

        XCTAssertEqual(usage.members.map { $0.identity.pid }, [10, 11])
    }

    func testSamplerWarmsUpWithMemoryRowsThenPublishesLiveCPU() async {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 1_000_000_000, memory: 400_000_000)
        ]
        let nextRecords = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 450_000_000)
        ]
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: records),
            .fixture(time: 2_000_000_000, records: nextRecords)
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        let warming = await sampler.sample()
        XCTAssertEqual(warming.status, .warmingUp)
        XCTAssertTrue(warming.byCPU.isEmpty)
        XCTAssertEqual(warming.byMemory.count, 1)
        XCTAssertNil(warming.byMemory.first?.cpuRawPercent)

        let live = await sampler.sample()
        XCTAssertEqual(live.status, .live)
        XCTAssertEqual(live.byCPU.first?.cpuRawPercent ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertEqual(live.byMemory.first?.physicalFootprintBytes, 450_000_000)
    }

    func testPrewarmIsIdempotentAndDoesNotSeedTheCPUBaseline() async {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 1_000_000_000, memory: 400_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 410_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 3_000_000_000, memory: 420_000_000),
        ]
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [records[0]]),
            .fixture(time: 2_000_000_000, records: [records[1]]),
            .fixture(time: 3_000_000_000, records: [records[2]]),
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        await sampler.prewarm()
        await sampler.prewarm()
        let captureCountAfterPrewarm = await provider.captureCount
        XCTAssertEqual(captureCountAfterPrewarm, 1)

        let firstVisible = await sampler.sample()
        let nextTick = await sampler.sample()
        XCTAssertEqual(firstVisible.status, .warmingUp)
        XCTAssertEqual(nextTick.status, .live)
        XCTAssertEqual(
            nextTick.byCPU.first?.cpuRawPercent ?? -.infinity,
            100,
            accuracy: 0.001
        )
    }

    func testSamplerSerializesConcurrentOutOfOrderCaptures() async {
        let older = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                           cpu: 1_000_000_000, memory: 400_000_000)
        let newer = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                           cpu: 2_000_000_000, memory: 450_000_000)
        let provider = OutOfOrderProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [older]),
            .fixture(time: 2_000_000_000, records: [newer])
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        let olderTask = Task { await sampler.sample() }
        await provider.waitUntilFirstCaptureStarts()
        let newerTask = Task { await sampler.sample() }
        let olderSnapshot = await olderTask.value
        let newerSnapshot = await newerTask.value

        XCTAssertEqual(olderSnapshot.status, .warmingUp)
        XCTAssertEqual(olderSnapshot.byMemory.first?.trend.memoryBytes, [400_000_000])
        XCTAssertEqual(newerSnapshot.status, .live)
        XCTAssertEqual(newerSnapshot.byCPU.first?.cpuRawPercent ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertEqual(newerSnapshot.byMemory.first?.trend.memoryBytes,
                       [400_000_000, 450_000_000])
    }

    func testResetWaitsForInFlightSampleAndPrecedesNextSample() async {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 1_000_000_000, memory: 400_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 410_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 3_000_000_000, memory: 420_000_000)
        ]
        let provider = ResetBarrierProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [records[0]]),
            .fixture(time: 2_000_000_000, records: [records[1]]),
            .fixture(time: 3_000_000_000, records: [records[2]])
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        let initialSnapshot = await sampler.sample()
        XCTAssertEqual(initialSnapshot.status, .warmingUp)
        let inFlightSample = Task { await sampler.sample() }
        await provider.waitUntilBlockedCaptureStarts()
        let reset = Task { await sampler.resetBaseline() }
        for _ in 0..<20 { await Task.yield() }
        await provider.releaseBlockedCapture()

        let inFlightSnapshot = await inFlightSample.value
        XCTAssertEqual(inFlightSnapshot.status, .live)
        _ = await reset.value
        let afterResetSnapshot = await sampler.sample()
        XCTAssertEqual(afterResetSnapshot.status, .warmingUp)
    }

    func testStaleEpochRequestSkipsCaptureAndPreservesPostResetWarmup() async {
        let records = [
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 1_000_000_000, memory: 400_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 2_000_000_000, memory: 410_000_000),
            record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                   cpu: 3_000_000_000, memory: 420_000_000)
        ]
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [records[0]]),
            .fixture(time: 2_000_000_000, records: [records[1]]),
            .fixture(time: 3_000_000_000, records: [records[2]])
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        let initial = await sampler.sample(requiringBaselineEpoch: 0)
        XCTAssertEqual(initial?.status, .warmingUp)

        let gate = AsyncTestGate()
        let delayedStaleRequest = Task {
            await gate.wait()
            return await sampler.sample(requiringBaselineEpoch: 0)
        }
        let newEpoch = await sampler.resetBaseline()
        await gate.open()

        let staleSnapshot = await delayedStaleRequest.value
        let captureCountAfterStaleRequest = await provider.captureCount
        XCTAssertNil(staleSnapshot)
        XCTAssertEqual(captureCountAfterStaleRequest, 1)

        let firstAccepted = await sampler.sample(requiringBaselineEpoch: newEpoch)
        let secondAccepted = await sampler.sample(requiringBaselineEpoch: newEpoch)
        XCTAssertEqual(firstAccepted?.status, .warmingUp)
        XCTAssertEqual(secondAccepted?.status, .live)
        let finalCaptureCount = await provider.captureCount
        XCTAssertEqual(finalCaptureCount, 3)
    }

    func testLegacyCompatibilityOmitsUnknownAndReusedPIDCPU() {
        let first = record(pid: 42, start: 1, path: "/usr/bin/fixture",
                           cpu: 1_000_000_000, memory: 10_000_000)
        let second = record(pid: 42, start: 1, path: "/usr/bin/fixture",
                            cpu: 2_000_000_000, memory: 11_000_000)
        let reused = record(pid: 42, start: 2, path: "/usr/bin/fixture",
                            cpu: 9_000_000_000, memory: 12_000_000)
        let captures = [
            ProcessCapture.fixture(time: 1_000_000_000, records: [first]),
            .fixture(time: 2_000_000_000, records: [second]),
            .fixture(time: 3_000_000_000, records: [reused])
        ]
        let source = LockedProcessCaptureSource(captures: captures)
        let sampler = ProcessSampler(
            provider: FixtureProcessSnapshotProvider(captures: [captures[0]]),
            logicalCPUCount: 8,
            legacyCapture: { source.next() }
        )

        let warming = sampler.sample(top: 6)
        XCTAssertTrue(warming.byCPU.isEmpty)
        XCTAssertEqual(warming.byMemory.map(\.id), [42])

        let live = sampler.sample(top: 6)
        XCTAssertEqual(live.byCPU.first?.cpuPercent ?? -.infinity,
                       100, accuracy: 0.001)

        let afterReuse = sampler.sample(top: 6)
        XCTAssertTrue(afterReuse.byCPU.isEmpty)
        XCTAssertEqual(afterReuse.byMemory.map(\.id), [42])
    }

    func testLegacyCompatibilityWarmsUpAfterLongGapAndUsesNewBaseline() {
        let records = [
            record(pid: 42, start: 1, path: "/usr/bin/fixture",
                   cpu: 1_000_000_000, memory: 10_000_000),
            record(pid: 42, start: 1, path: "/usr/bin/fixture",
                   cpu: 2_000_000_000, memory: 10_000_000),
            record(pid: 42, start: 1, path: "/usr/bin/fixture",
                   cpu: 3_000_000_000, memory: 10_000_000),
            record(pid: 42, start: 1, path: "/usr/bin/fixture",
                   cpu: 4_000_000_000, memory: 10_000_000)
        ]
        let captures = [
            ProcessCapture.fixture(time: 1_000_000_000, records: [records[0]]),
            .fixture(time: 2_000_000_000, records: [records[1]]),
            .fixture(time: 30_000_000_000, records: [records[2]]),
            .fixture(time: 31_000_000_000, records: [records[3]])
        ]
        let source = LockedProcessCaptureSource(captures: captures)
        let sampler = ProcessSampler(
            provider: FixtureProcessSnapshotProvider(captures: [captures[0]]),
            logicalCPUCount: 8,
            legacyCapture: { source.next() }
        )

        XCTAssertTrue(sampler.sample(top: 6).byCPU.isEmpty)
        XCTAssertEqual(sampler.sample(top: 6).byCPU.first?.cpuPercent ?? -.infinity,
                       100, accuracy: 0.001)
        XCTAssertTrue(sampler.sample(top: 6).byCPU.isEmpty)
        XCTAssertEqual(sampler.sample(top: 6).byCPU.first?.cpuPercent ?? -.infinity,
                       100, accuracy: 0.001)
    }

    func testSamplerCapsTrendsAtSixtySamples() async {
        var captures: [ProcessCapture] = []
        for index in 0..<62 {
            let time = UInt64(index + 1) * 1_000_000_000
            let sample = record(
                pid: 10,
                path: "/Applications/Demo.app/Contents/MacOS/Demo",
                cpu: time,
                memory: 400_000_000 + Int64(index)
            )
            captures.append(.fixture(time: time, records: [sample]))
        }
        let provider = FixtureProcessSnapshotProvider(captures: captures)
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        var latest: ApplicationUsageSnapshot?
        for _ in captures {
            latest = await sampler.sample()
        }

        XCTAssertEqual(latest?.byMemory.first?.trend.cpuRaw.count, 60)
        XCTAssertEqual(latest?.byMemory.first?.trend.memoryBytes.count, 60)
    }

    func testSamplerDropsTrendAfterApplicationIsAbsentForOver120Seconds() async {
        let first = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                           cpu: 1_000_000_000, memory: 400_000_000)
        let second = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                            cpu: 2_000_000_000, memory: 410_000_000)
        let returned = record(pid: 10, path: "/Applications/Demo.app/Contents/MacOS/Demo",
                              cpu: 3_000_000_000, memory: 420_000_000)
        let provider = FixtureProcessSnapshotProvider(captures: [
            .fixture(time: 1_000_000_000, records: [first]),
            .fixture(time: 2_000_000_000, records: [second]),
            .fixture(time: 123_000_000_000, records: []),
            .fixture(time: 124_000_000_000, records: [returned])
        ])
        let sampler = ProcessSampler(provider: provider, logicalCPUCount: 8)

        _ = await sampler.sample()
        _ = await sampler.sample()
        _ = await sampler.sample()
        let latest = await sampler.sample()

        XCTAssertEqual(latest.byMemory.first?.trend.memoryBytes, [420_000_000])
    }
}

private extension ProcessCapture {
    static func fixture(time: UInt64, cpu: UInt64, start: UInt64) -> Self {
        let record = ProcessResourceRecord(pid: 42, parentPID: 1,
                                           startTimeNanoseconds: start,
                                           name: "fixture", executablePath: "/usr/bin/fixture",
                                           cpuTimeNanoseconds: cpu,
                                           physicalFootprintBytes: 1_000_000,
                                           peakFootprintBytes: 1_000_000)
        return ProcessCapture(records: [record], failures: [:],
                              wallDate: Date(timeIntervalSince1970: Double(time) / 1_000_000_000),
                              monotonicNanoseconds: time, source: .local, enumeratedCount: 1)
    }

    static func fixture(time: UInt64, records: [ProcessResourceRecord]) -> Self {
        ProcessCapture(
            records: records,
            failures: [:],
            wallDate: Date(timeIntervalSince1970: Double(time) / 1_000_000_000),
            monotonicNanoseconds: time,
            source: .local,
            enumeratedCount: records.count
        )
    }
}

private extension ApplicationUsage {
    static func fixture(id: String, rawCPU: Double?, memory: Int64) -> Self {
        let process = ProcessIdentity(pid: Int32(id.utf8.first ?? 1), startTimeNanoseconds: 1)
        return ApplicationUsage(
            id: ApplicationIdentity(rawValue: id), displayName: id,
            bundleIdentifier: nil, bundlePath: nil, representativePID: process.pid,
            members: [ApplicationMemberUsage(identity: process, name: id,
                                             cpuRawPercent: rawCPU,
                                             physicalFootprintBytes: memory)],
            cpuRawPercent: rawCPU, cpuNormalizedPercent: rawCPU.map { $0 / 8 },
            physicalFootprintBytes: memory, peakFootprintBytes: memory,
            trend: ApplicationUsageTrend(cpuRaw: [], memoryBytes: []))
    }
}

private actor FixtureProcessSnapshotProvider: ProcessSnapshotProviding {
    private let captures: [ProcessCapture]
    private var index = 0

    init(captures: [ProcessCapture]) {
        self.captures = captures
    }

    var captureCount: Int { index }

    func capture() async -> ProcessCapture {
        defer { index += 1 }
        return captures[min(index, captures.count - 1)]
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor OutOfOrderProcessSnapshotProvider: ProcessSnapshotProviding {
    private let captures: [ProcessCapture]
    private var index = 0
    private var firstCaptureStarted = false
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []

    init(captures: [ProcessCapture]) {
        self.captures = captures
    }

    func waitUntilFirstCaptureStarts() async {
        if firstCaptureStarted { return }
        await withCheckedContinuation { continuation in
            firstCaptureWaiters.append(continuation)
        }
    }

    func capture() async -> ProcessCapture {
        let captureIndex = index
        index += 1
        if captureIndex == 0 {
            firstCaptureStarted = true
            let waiters = firstCaptureWaiters
            firstCaptureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            try? await Task.sleep(for: .milliseconds(100))
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return captures[min(captureIndex, captures.count - 1)]
    }
}

private actor ResetBarrierProcessSnapshotProvider: ProcessSnapshotProviding {
    private let captures: [ProcessCapture]
    private var index = 0
    private var blockedCaptureStarted = false
    private var blockedCaptureWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedCaptureContinuation: CheckedContinuation<Void, Never>?

    init(captures: [ProcessCapture]) {
        self.captures = captures
    }

    func waitUntilBlockedCaptureStarts() async {
        if blockedCaptureStarted { return }
        await withCheckedContinuation { continuation in
            blockedCaptureWaiters.append(continuation)
        }
    }

    func releaseBlockedCapture() {
        blockedCaptureContinuation?.resume()
        blockedCaptureContinuation = nil
    }

    func capture() async -> ProcessCapture {
        let captureIndex = index
        index += 1
        if captureIndex == 1 {
            blockedCaptureStarted = true
            let waiters = blockedCaptureWaiters
            blockedCaptureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                blockedCaptureContinuation = continuation
            }
        }
        return captures[min(captureIndex, captures.count - 1)]
    }
}

private final class LockedProcessCaptureSource: @unchecked Sendable {
    private let lock = NSLock()
    private let captures: [ProcessCapture]
    private var index = 0

    init(captures: [ProcessCapture]) {
        self.captures = captures
    }

    func next() -> ProcessCapture {
        lock.lock()
        defer { lock.unlock() }
        defer { index += 1 }
        return captures[min(index, captures.count - 1)]
    }
}

private struct DictionaryMetadataProvider: ApplicationMetadataProviding {
    let metadataByPath: [String: ApplicationMetadata]

    func metadata(forApplicationAt path: String) -> ApplicationMetadata {
        metadataByPath[path] ?? ApplicationMetadata(bundleIdentifier: nil, displayName: nil)
    }
}

private final class CountingMetadataProvider: ApplicationMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: ApplicationMetadata
    private var count = 0

    init(metadata: ApplicationMetadata) {
        self.metadata = metadata
    }

    var invocationCount: Int { lock.withLock { count } }

    func metadata(forApplicationAt path: String) -> ApplicationMetadata {
        lock.withLock { count += 1 }
        return metadata
    }
}

private final class CountingApplicationPathResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int { lock.withLock { count } }

    func resolve(_ executablePath: String) -> String? {
        lock.withLock { count += 1 }
        return ApplicationOwnershipResolver.outermostApplicationPath(in: executablePath)
    }
}
