import Foundation
import XCTest
import Domain
@testable import Infrastructure

final class ThreatRemediationOutcomeTests: XCTestCase {
    func testEmptyInventoryReturnsReducerBackedFailureInsteadOfCrashing() async {
        let operationID = UUID()
        let parentID = UUID()
        let labels = StubLabelReader(defaultResult: .label("com.xico.unused"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: URL(fileURLWithPath: "/unused-test-root", isDirectory: true),
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            [],
            operationID: operationID,
            parentID: parentID)

        XCTAssertEqual(result.outcome.id, operationID)
        XCTAssertEqual(result.outcome.parentID, parentID)
        XCTAssertEqual(result.outcome.kind, .threatRemediation)
        XCTAssertEqual(result.outcome.status, .failure)
        XCTAssertEqual(result.outcome.counts.requested, 0)
        XCTAssertEqual(result.outcome.mutation, .none)
        XCTAssertTrue(result.outcome.issues.contains {
            $0.code == "threat.remediation.request.invalid"
                && $0.category == .internalInvariant
                && $0.retryable
        })
        XCTAssertTrue(result.payload.items.isEmpty)
        XCTAssertEqual(labels.readCount, 0)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testDuplicateRequestIDsFailClosedBeforeAnyDependency() async throws {
        let duplicateID = UUID()
        let requests = [
            ThreatRemediationRequest(
                requestID: duplicateID,
                relatedCleaningRequestID: UUID(),
                url: URL(fileURLWithPath: "/private/duplicate-a.plist")),
            ThreatRemediationRequest(
                requestID: duplicateID,
                relatedCleaningRequestID: UUID(),
                url: URL(fileURLWithPath: "/private/duplicate-b.plist"))
        ]
        let labels = StubLabelReader(defaultResult: .label("com.xico.unused"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: URL(fileURLWithPath: "/unused-test-root", isDirectory: true),
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            requests,
            operationID: UUID(),
            parentID: UUID())

        XCTAssertEqual(result.outcome.status, .failure)
        XCTAssertEqual(result.outcome.counts.requested, 2)
        XCTAssertEqual(result.outcome.counts.failed, 2)
        XCTAssertEqual(result.outcome.mutation, .none)
        XCTAssertEqual(result.payload.items.count, 2)
        for item in result.payload.items {
            let issue = try failedIssue(item.disposition)
            XCTAssertEqual(issue.code, "threat.remediation.request.invalid")
            XCTAssertEqual(issue.category, .internalInvariant)
            XCTAssertEqual(issue.recovery, .retry)
            XCTAssertTrue(issue.retryable)
            XCTAssertEqual(item.mutation, .none)
        }
        XCTAssertEqual(labels.readCount, 0)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testRejectsAnythingOtherThanDirectNonsymlinkRegularPlistChildren() async throws {
        let fixture = try TemporaryLaunchAgents()
        let direct = try fixture.makeFile("direct.plist")
        let nestedDirectory = try fixture.makeDirectory("Nested")
        let nested = try fixture.makeFile("nested.plist", in: nestedDirectory)
        let plain = try fixture.makeFile("plain.txt")
        let directory = try fixture.makeDirectory("directory.plist")
        let outside = try fixture.makeOutsideFile("outside.plist")
        let symlink = try fixture.makeSymlink("alias.plist", destination: direct)
        let requests = [nested, plain, directory, outside, symlink, direct]
            .map { request($0) }
        let labels = StubLabelReader(defaultResult: .label("com.xico.direct"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [.notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            requests,
            operationID: UUID(),
            parentID: UUID())

        XCTAssertEqual(result.payload.items.count, requests.count)
        for item in result.payload.items.dropLast() {
            let issue = try skippedIssue(item.disposition)
            XCTAssertEqual(issue.code, "threat.remediation.target.ineligible")
            XCTAssertEqual(issue.category, .safetyPolicy)
            XCTAssertEqual(issue.recovery, .none)
            XCTAssertFalse(issue.retryable)
            XCTAssertEqual(item.mutation, .none)
        }
        XCTAssertEqual(result.payload.items.last?.disposition, .unchanged)
        XCTAssertEqual(result.payload.items.last?.mutation, OperationMutationFact.none)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 0)
    }

    func testSymlinkRootIsRejectedBeforeReadingOtherwiseRegularChild() async throws {
        let fixture = try TemporaryLaunchAgents()
        let direct = try fixture.makeFile("direct.plist")
        let symlinkRoot = try fixture.makeRootSymlink("LaunchAgentsAlias")
        let candidateThroughSymlink = symlinkRoot
            .appendingPathComponent(direct.lastPathComponent)
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: symlinkRoot,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            [request(candidateThroughSymlink)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try skippedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.target.ineligible")
        XCTAssertEqual(issue.category, .safetyPolicy)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(labels.readCount, 0)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testMissingLabelNeverFallsBackToFilename() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("com.xico.looks-valid.plist")
        let labels = StubLabelReader(defaultResult: .missing)
        let controller = StubLaunchAgentController(results: [])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: StubPostcondition(states: []))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try skippedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.label.missing")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .none)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 0)
    }

    func testUnreadableLabelProducesStableNonretryableFailureWithoutMutation() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .unreadable),
            controller: StubLaunchAgentController(results: []),
            postcondition: StubPostcondition(states: []))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.label.unreadable")
        XCTAssertEqual(issue.category, .io)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertNil(item.retryToken)
    }

    func testOversizedPlistFailsClosedBeforeParserOrDependencies() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile(
            "oversized.plist",
            data: Data(repeating: 0x41, count: 1_048_577))
        let labels = StubLabelReader(defaultResult: .label("com.xico.oversized"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.target.tooLarge")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertNil(item.retryToken)
        XCTAssertEqual(labels.readCount, 0)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testTraversalSpellingIsRejectedEvenWhenStandardizedPathIsDirectChild() async throws {
        let fixture = try TemporaryLaunchAgents()
        _ = try fixture.makeFile("agent.plist")
        let traversal = URL(
            fileURLWithPath: fixture.root.path + "/nested/../agent.plist")
        XCTAssertEqual(traversal.standardizedFileURL.deletingLastPathComponent(), fixture.root)
        XCTAssertTrue(traversal.pathComponents.contains(".."))
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: StubLaunchAgentController(results: []),
            postcondition: StubPostcondition(states: []))

        let result = await service.remediate(
            [request(traversal)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try skippedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.target.ineligible")
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(labels.readCount, 0)
    }

    func testPathSwapAfterOpenCannotChangeLabelReadFromOriginalDescriptor() async throws {
        let fixture = try TemporaryLaunchAgents()
        let original = try fixture.makePlist(
            "agent.plist",
            label: "com.xico.original")
        let replacement = try fixture.makeOutsidePlist(
            "replacement.plist",
            label: "com.xico.replacement")
        let labels = MutatingPropertyListLabelReader {
            try? fixture.replaceFileWithSymlink(original, destination: replacement)
        }
        let postcondition = StubPostcondition(states: [.notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: StubLaunchAgentController(results: []),
            postcondition: postcondition)

        let result = await service.remediate(
            [request(original)],
            operationID: UUID(),
            parentID: UUID())

        XCTAssertEqual(result.payload.items.first?.disposition, .unchanged)
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(postconditionCalls, [
            LaunchAgentCall(uid: 4242, label: "com.xico.original")
        ])
        XCTAssertEqual(labels.readCount, 1)
    }

    func testRootDirectoryReplacementDuringLabelReadFailsClosed() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.original")
        let labels = MutatingPropertyListLabelReader {
            try? fixture.replaceRootWithFreshDirectory()
        }
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try skippedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.target.ineligible")
        XCTAssertEqual(issue.category, .safetyPolicy)
        XCTAssertFalse(issue.retryable)
        XCTAssertNil(item.retryToken)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testLabelValidationUsesExactASCIIAllowlistAnd512ByteLimit() {
        XCTAssertTrue(ThreatRemediation.isValidLaunchdLabel("Az09._-"))
        XCTAssertTrue(ThreatRemediation.isValidLaunchdLabel(String(repeating: "a", count: 512)))

        XCTAssertFalse(ThreatRemediation.isValidLaunchdLabel(""))
        XCTAssertFalse(ThreatRemediation.isValidLaunchdLabel(String(repeating: "a", count: 513)))
        XCTAssertFalse(ThreatRemediation.isValidLaunchdLabel("com.xico agent"))
        XCTAssertFalse(ThreatRemediation.isValidLaunchdLabel("com/xico"))
        XCTAssertTrue(ThreatRemediation.isValidLaunchdLabel("-leading-is-allowed"))
        XCTAssertFalse(ThreatRemediation.isValidLaunchdLabel("com.xico.é"))
    }

    func testConcreteExecutorIsInternalAndLegacyStaticBridgeIsAbsent() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productionURL = packageRoot
            .appendingPathComponent("Sources/Infrastructure/ThreatRemediation.swift")
        let productionSource = try String(contentsOf: productionURL, encoding: .utf8)
        XCTAssertFalse(productionSource.contains("public struct ThreatRemediation"))
        XCTAssertFalse(productionSource.contains("bootoutUserAgents"))

        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: buildRoot,
                includingPropertiesForKeys: [.isDirectoryKey]))
        var moduleSearchDirectory: URL?
        for case let url as URL in enumerator where url.lastPathComponent == "Infrastructure.swiftmodule" {
            moduleSearchDirectory = url.deletingLastPathComponent()
            break
        }
        let modules = try XCTUnwrap(
            moduleSearchDirectory,
            "swift test must have built Infrastructure before this compile-boundary check")
        let configurationRoot = modules.deletingLastPathComponent()
        let clangModuleMaps = ["CProcessBatch", "CSensors"].map {
            configurationRoot
                .appendingPathComponent("\($0).build", isDirectory: true)
                .appendingPathComponent("module.modulemap")
        }
        for moduleMap in clangModuleMaps {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: moduleMap.path),
                "Missing generated Clang module map: \(moduleMap.path)")
        }
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-threat-visibility-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let fixtureURL = fixtureDirectory.appendingPathComponent("Visibility.swift")
        try Data("import Infrastructure\nlet executor = ThreatRemediation()\n".utf8)
            .write(to: fixtureURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-I", modules.path]
            + clangModuleMaps.flatMap {
                ["-Xcc", "-fmodule-map-file=\($0.path)"]
            }
            + [fixtureURL.path]
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFT_MODULECACHE_PATH"] = fixtureDirectory
            .appendingPathComponent("swift-module-cache").path
        environment["CLANG_MODULE_CACHE_PATH"] = fixtureDirectory
            .appendingPathComponent("clang-module-cache").path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            diagnostic.contains("ThreatRemediation")
                && (diagnostic.contains("cannot find")
                    || diagnostic.contains("inaccessible")
                    || diagnostic.contains("no accessible initializers")),
            diagnostic)
    }

    func testInvalidDeclaredLabelIsSkippedAsValidationFailure() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let controller = StubLaunchAgentController(results: [])
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico/unsafe")),
            controller: controller,
            postcondition: StubPostcondition(states: []))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try skippedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.label.invalid")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .none)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 0)
    }

    func testConfirmedNotLoadedIsUnchangedAndDoesNotInvokeBootout() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let controller = StubLaunchAgentController(results: [])
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: controller,
            postcondition: StubPostcondition(states: [.notLoaded]))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        XCTAssertEqual(item.disposition, .unchanged)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(result.outcome.status, .success)
        XCTAssertEqual(result.outcome.counts.unchanged, 1)
        XCTAssertEqual(result.outcome.mutation, .none)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 0)
    }

    func testConfirmedBootoutIsSucceededAndChanged() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let operationID = UUID()
        let parentID = UUID()
        let remediationRequest = request(plist)
        let controller = StubLaunchAgentController(results: [.invoked])
        let postcondition = StubPostcondition(states: [.loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: controller,
            postcondition: postcondition)

        let result = await service.remediate(
            [remediationRequest],
            operationID: operationID,
            parentID: parentID)

        let item = try XCTUnwrap(result.payload.items.first)
        XCTAssertEqual(item.requestID, remediationRequest.requestID)
        XCTAssertEqual(item.relatedCleaningRequestID,
                       remediationRequest.relatedCleaningRequestID)
        XCTAssertEqual(item.url, plist)
        XCTAssertEqual(item.disposition, .succeeded)
        XCTAssertEqual(item.mutation, .changed)
        XCTAssertEqual(result.outcome.id, operationID)
        XCTAssertEqual(result.outcome.parentID, parentID)
        XCTAssertEqual(result.outcome.kind, .threatRemediation)
        XCTAssertEqual(result.outcome.status, .success)
        XCTAssertEqual(result.outcome.counts.succeeded, 1)
        XCTAssertEqual(result.outcome.mutation, .changed)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls, [
            LaunchAgentCall(uid: 4242, label: "com.xico.agent")
        ])
    }

    func testUnknownPostconditionAfterInvocationFailsAsPossiblyChanged() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("private-path-agent.plist")
        let secretLabel = "com.secret.agent"
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label(secretLabel)),
            controller: StubLaunchAgentController(results: [.invoked]),
            postcondition: StubPostcondition(states: [.loaded, .unknown]))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.bootout.notConfirmed")
        XCTAssertEqual(issue.category, .io)
        XCTAssertEqual(issue.recovery, .retry)
        XCTAssertTrue(issue.retryable)
        XCTAssertFalse(issue.code.contains(plist.path))
        XCTAssertFalse(issue.code.contains(secretLabel))
        XCTAssertEqual(item.mutation, .possiblyChanged)
        XCTAssertEqual(result.outcome.status, .failure)
        XCTAssertEqual(result.outcome.mutation, .possiblyChanged)
    }

    func testStillLoadedAfterInvocationFailsConservativelyAsPossiblyChanged() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: StubLaunchAgentController(results: [.invoked]),
            postcondition: StubPostcondition(states: [.loaded, .loaded]))

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.bootout.notConfirmed")
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(item.mutation, .possiblyChanged)
    }

    func testControllerThatCannotInvokeFailsWithoutMutation() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makeFile("agent.plist")
        let postcondition = StubPostcondition(states: [.loaded])
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: StubLaunchAgentController(results: [.notInvoked]),
            postcondition: postcondition)

        let result = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.bootout.notInvoked")
        XCTAssertEqual(issue.category, .unavailable)
        XCTAssertEqual(issue.recovery, .retry)
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        let token = try XCTUnwrap(item.retryToken)
        XCTAssertEqual(token.validatedLabel, "com.xico.agent")
        XCTAssertEqual(token.rootRelativeIdentity, "agent.plist")
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(postconditionCalls.count, 1)
    }

    func testRetryTokenRunsAfterPlistWasRemovedWithoutReadingPathAgain() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)
        let firstRequest = request(plist)

        let first = await service.remediate(
            [firstRequest],
            operationID: UUID(),
            parentID: UUID())
        let token = try XCTUnwrap(first.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        let retryRequest = ThreatRemediationRequest(
            requestID: UUID(),
            relatedCleaningRequestID: UUID(),
            url: plist,
            retryToken: token)

        let retried = await service.remediate(
            [retryRequest],
            operationID: UUID(),
            parentID: UUID())

        let retriedItem = try XCTUnwrap(retried.payload.items.first)
        XCTAssertEqual(retriedItem.requestID, retryRequest.requestID)
        XCTAssertEqual(retriedItem.relatedCleaningRequestID,
                       retryRequest.relatedCleaningRequestID)
        XCTAssertEqual(retriedItem.url, retryRequest.url)
        XCTAssertEqual(retriedItem.retryToken, token)
        XCTAssertEqual(retriedItem.disposition, .unchanged)
        XCTAssertEqual(labels.readCount, 1, "retry must not reopen the removed plist")
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.map(\.label), [
            "com.xico.agent", "com.xico.agent"
        ])
    }

    func testMixedCasePlistExtensionSupportsFreshProofAndDeletedTargetRetry() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("Agent.PLIST", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let first = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(first.payload.items.first?.retryToken)
        XCTAssertEqual(token.rootRelativeIdentity, "Agent.PLIST")
        try FileManager.default.removeItem(at: plist)
        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)

        let retried = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        XCTAssertEqual(retried.payload.items.first?.disposition, .unchanged)
        XCTAssertEqual(
            retried.payload.items.first?.mutation,
            OperationMutationFact.none)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 2)
    }

    func testExpiredRetryAuthorizationFailsClosedBeforeDependencies() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded])
        let clock = TestMonotonicClock(now: 100)
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition,
            retryAuthorizationLifetimeNanoseconds: 10,
            monotonicNow: { clock.read() })

        let first = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(first.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        clock.advance(by: 10)
        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)

        let result = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.retryToken.invalid")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 1)
    }

    func testBatchCompletionAnchorsTTLAfterSlowLaterItems() async throws {
        let fixture = try TemporaryLaunchAgents()
        let firstURL = try fixture.makePlist("first.plist", label: "com.xico.first")
        let secondURL = try fixture.makePlist("second.plist", label: "com.xico.second")
        let clock = TestMonotonicClock(now: 100)
        let labels = PropertyListLaunchAgentLabelReader()
        let controller = StubLaunchAgentController(results: [.notInvoked, .notInvoked])
        let postcondition = ClockAdvancingPostcondition(
            clock: clock,
            steps: [
                TimedLoadState(state: .loaded, advance: 0),
                TimedLoadState(state: .loaded, advance: 20),
                TimedLoadState(state: .notLoaded, advance: 0),
            ])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition,
            retryAuthorizationLifetimeNanoseconds: 10,
            monotonicNow: { clock.read() })

        let initial = await service.remediate(
            [request(firstURL), request(secondURL)],
            operationID: UUID(),
            parentID: UUID())
        let firstToken = try XCTUnwrap(initial.payload.items.first?.retryToken)
        let secondToken = try XCTUnwrap(initial.payload.items.last?.retryToken)
        XCTAssertEqual(clock.read(), 120)

        // Even though the first item exceeded one full TTL while the second ran, the batch return
        // refreshes both proven authorizations at t=120.
        try FileManager.default.removeItem(at: firstURL)
        let immediateRetry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: firstURL, retryToken: firstToken)
        let immediate = await service.remediate(
            [immediateRetry], operationID: UUID(), parentID: UUID())
        XCTAssertEqual(immediate.payload.items.first?.disposition, .unchanged)

        // An untouched sibling token still expires after a full user-action window.
        clock.advance(by: 10)
        try FileManager.default.removeItem(at: secondURL)
        let lateRetry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: secondURL, retryToken: secondToken)
        let late = await service.remediate(
            [lateRetry], operationID: UUID(), parentID: UUID())
        let lateItem = try XCTUnwrap(late.payload.items.first)
        let lateIssue = try failedIssue(lateItem.disposition)
        XCTAssertEqual(lateIssue.code, "threat.remediation.retryToken.invalid")
        XCTAssertFalse(lateIssue.retryable)
        XCTAssertEqual(lateItem.mutation, .none)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 2)
        XCTAssertEqual(postconditionCalls.count, 3)
    }

    func testRetryTokenRejectsRecreatedRegularTargetBeforeDependencies() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let first = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(first.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        try Data("replacement".utf8).write(to: plist)
        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)

        let result = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.retryToken.staleTarget")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 1)
    }

    func testRetryTokenRejectsRecreatedSymlinkTargetBeforeDependencies() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let outside = try fixture.makeOutsidePlist(
            "replacement.plist", label: "com.xico.replacement")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let first = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(first.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        try FileManager.default.createSymbolicLink(
            at: plist, withDestinationURL: outside)
        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)

        let result = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.retryToken.staleTarget")
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 1)
    }

    func testOverlimitBatchFailsEntireInventoryWithoutDependenciesOrTokenEviction() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)

        let issued = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(issued.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        let overlimit = (0...256).map { index in
            request(fixture.root.appendingPathComponent("overlimit-\(index).plist"))
        }

        let rejected = await service.remediate(
            overlimit, operationID: UUID(), parentID: UUID())

        XCTAssertTrue(rejected.payload.items.isEmpty)
        XCTAssertEqual(rejected.outcome.counts.requested, 257)
        XCTAssertEqual(rejected.outcome.counts.failed, 257)
        XCTAssertEqual(rejected.outcome.mutation, .none)
        let issue = try XCTUnwrap(rejected.outcome.issues.first)
        XCTAssertEqual(rejected.outcome.issues.count, 1)
        XCTAssertEqual(issue.code, "threat.remediation.request.tooMany")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertNil(issue.subjectID)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCallsBeforeRetry = await controller.recordedCalls()
        let postconditionCallsBeforeRetry = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCallsBeforeRetry.count, 1)
        XCTAssertEqual(postconditionCallsBeforeRetry.count, 1)

        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)
        let retried = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        XCTAssertEqual(retried.payload.items.first?.disposition, .unchanged)
        XCTAssertEqual(labels.readCount, 1)
        let controllerCallsAfterRetry = await controller.recordedCalls()
        let postconditionCallsAfterRetry = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCallsAfterRetry.count, 1)
        XCTAssertEqual(postconditionCallsAfterRetry.count, 2)
    }

    func testVeryLargeInventoryUsesBoundedAggregateAdmissionFailure() async throws {
        let root = URL(fileURLWithPath: "/unused-threat-large-inventory", isDirectory: true)
        let labels = StubLabelReader(defaultResult: .label("com.xico.unused"))
        let controller = StubLaunchAgentController(results: [])
        let postcondition = StubPostcondition(states: [])
        let service = remediation(
            root: root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)
        let count = 50_000
        let requests = (0..<count).map { index in
            ThreatRemediationRequest(
                requestID: UUID(),
                relatedCleaningRequestID: UUID(),
                url: root.appendingPathComponent("agent-\(index).plist"))
        }

        let result = await service.remediate(
            requests, operationID: UUID(), parentID: UUID())

        XCTAssertTrue(result.payload.items.isEmpty)
        XCTAssertEqual(result.outcome.counts.requested, count)
        XCTAssertEqual(result.outcome.counts.failed, count)
        XCTAssertEqual(result.outcome.counts.succeeded, 0)
        XCTAssertEqual(result.outcome.mutation, .none)
        let issue = try XCTUnwrap(result.outcome.issues.first)
        XCTAssertEqual(result.outcome.issues.count, 1)
        XCTAssertEqual(issue.code, "threat.remediation.request.tooMany")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertNil(issue.subjectID)
        XCTAssertEqual(labels.readCount, 0)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCalls.isEmpty)
        XCTAssertTrue(postconditionCalls.isEmpty)
    }

    func testAuthorizationCapacityFailsClosedWithoutEvictingLiveToken() async throws {
        let fixture = try TemporaryLaunchAgents()
        let firstURL = try fixture.makePlist("first.plist", label: "com.xico.first")
        let secondURL = try fixture.makePlist("second.plist", label: "com.xico.second")
        let thirdURL = try fixture.makePlist("third.plist", label: "com.xico.third")
        let labels = PropertyListLaunchAgentLabelReader()
        let controller = StubLaunchAgentController(results: [.notInvoked, .notInvoked])
        let postcondition = StubPostcondition(states: [.loaded, .loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition,
            retryAuthorizationCapacity: 2)

        let first = await service.remediate(
            [request(firstURL)], operationID: UUID(), parentID: UUID())
        let firstToken = try XCTUnwrap(first.payload.items.first?.retryToken)
        let second = await service.remediate(
            [request(secondURL)], operationID: UUID(), parentID: UUID())
        XCTAssertNotNil(second.payload.items.first?.retryToken)

        let third = await service.remediate(
            [request(thirdURL)], operationID: UUID(), parentID: UUID())

        let thirdItem = try XCTUnwrap(third.payload.items.first)
        let capacityIssue = try failedIssue(thirdItem.disposition)
        XCTAssertEqual(capacityIssue.code, "threat.remediation.retryToken.capacity")
        XCTAssertEqual(capacityIssue.category, .unavailable)
        XCTAssertEqual(capacityIssue.recovery, .manualAction)
        XCTAssertFalse(capacityIssue.retryable)
        XCTAssertEqual(thirdItem.mutation, .none)
        XCTAssertNil(thirdItem.retryToken)
        let controllerCallsAtCapacity = await controller.recordedCalls()
        let postconditionCallsAtCapacity = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCallsAtCapacity.count, 2)
        XCTAssertEqual(postconditionCallsAtCapacity.count, 2)

        try FileManager.default.removeItem(at: firstURL)
        let retry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: firstURL, retryToken: firstToken)
        let retried = await service.remediate(
            [retry], operationID: UUID(), parentID: UUID())

        XCTAssertEqual(retried.payload.items.first?.disposition, .unchanged)
        let controllerCallsAfterRetry = await controller.recordedCalls()
        let postconditionCallsAfterRetry = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCallsAfterRetry.count, 2)
        XCTAssertEqual(postconditionCallsAfterRetry.count, 3)
    }

    func testSecureNilTokenRereadRefreshesAvailableAuthorization() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let controller = StubLaunchAgentController(results: [.notInvoked, .invoked])
        let postcondition = StubPostcondition(states: [.loaded, .loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: PropertyListLaunchAgentLabelReader(),
            controller: controller,
            postcondition: postcondition)
        let first = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        XCTAssertNotNil(first.payload.items.first?.retryToken)

        // Domain intentionally omits the old token when D still needs the source plist. The
        // second call must use its fresh descriptor-backed label proof and refresh the same slot.
        let reread = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())

        let item = try XCTUnwrap(reread.payload.items.first)
        XCTAssertEqual(item.disposition, .succeeded)
        XCTAssertEqual(item.mutation, .changed)
        XCTAssertNil(item.retryToken)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 2)
        XCTAssertEqual(postconditionCalls.count, 3)
    }

    func testConcurrentSecureRereadRejectsInUseAuthorizationAsCollision() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = BlockingInitialPostcondition()
        let service = remediation(
            root: fixture.root,
            labelReader: PropertyListLaunchAgentLabelReader(),
            controller: controller,
            postcondition: postcondition)
        let firstRequest = request(plist)

        let firstTask = Task {
            await service.remediate(
                [firstRequest], operationID: UUID(), parentID: UUID())
        }
        await postcondition.waitUntilProbeStarts()
        let concurrent = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())

        let item = try XCTUnwrap(concurrent.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.retryToken.collision")
        XCTAssertEqual(issue.category, .validation)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(item.mutation, .none)
        XCTAssertNil(item.retryToken)
        let controllerCallsDuringCollision = await controller.recordedCalls()
        let postconditionCallsDuringCollision = await postcondition.recordedCalls()
        XCTAssertTrue(controllerCallsDuringCollision.isEmpty)
        XCTAssertEqual(postconditionCallsDuringCollision.count, 1)
        await postcondition.releaseProbe()
        let first = await firstTask.value

        XCTAssertNotNil(first.payload.items.first?.retryToken)
        let controllerCallsAfterRelease = await controller.recordedCalls()
        let postconditionCallsAfterRelease = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCallsAfterRelease.count, 1)
        XCTAssertEqual(postconditionCallsAfterRelease.count, 1)
    }

    func testConcurrentRetryAtomicallyClaimsTokenExactlyOnce() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = BlockingRetryPostcondition()
        let service = remediation(
            root: fixture.root,
            labelReader: PropertyListLaunchAgentLabelReader(),
            controller: controller,
            postcondition: postcondition)
        let issued = await service.remediate(
            [request(plist)], operationID: UUID(), parentID: UUID())
        let token = try XCTUnwrap(issued.payload.items.first?.retryToken)
        try FileManager.default.removeItem(at: plist)
        let firstRetry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)
        let secondRetry = ThreatRemediationRequest(
            requestID: UUID(), relatedCleaningRequestID: UUID(),
            url: plist, retryToken: token)

        let firstTask = Task {
            await service.remediate(
                [firstRetry], operationID: UUID(), parentID: UUID())
        }
        await postcondition.waitUntilRetryProbeStarts()
        let secondResult = await service.remediate(
            [secondRetry], operationID: UUID(), parentID: UUID())

        let secondItem = try XCTUnwrap(secondResult.payload.items.first)
        let issue = try failedIssue(secondItem.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.retryToken.inUse")
        XCTAssertEqual(issue.category, .unavailable)
        XCTAssertEqual(issue.recovery, .manualAction)
        XCTAssertFalse(issue.retryable)
        XCTAssertEqual(secondItem.mutation, .none)
        await postcondition.releaseRetryProbe()
        let firstResult = await firstTask.value

        XCTAssertEqual(firstResult.payload.items.first?.disposition, .unchanged)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 2)
    }

    func testIssuedRetryTokenRejectsWrongRootAndUnissuedTokenFailsClosed() async throws {
        let fixture = try TemporaryLaunchAgents()
        let other = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let wrongRootURL = try other.makePlist("agent.plist", label: "com.xico.agent")
        let labels = StubLabelReader(defaultResult: .label("com.xico.agent"))
        let controller = StubLaunchAgentController(results: [.notInvoked])
        let postcondition = StubPostcondition(states: [.loaded])
        let service = remediation(
            root: fixture.root,
            labelReader: labels,
            controller: controller,
            postcondition: postcondition)
        let issued = await service.remediate(
            [request(plist)],
            operationID: UUID(),
            parentID: UUID())
        let token = try XCTUnwrap(issued.payload.items.first?.retryToken)
        let fabricated = try XCTUnwrap(ThreatRemediationRetryToken(
            validatedLabel: "com.xico.fabricated",
            rootRelativeIdentity: "agent.plist"))
        let retryRequests = [
            ThreatRemediationRequest(
                requestID: UUID(), relatedCleaningRequestID: UUID(),
                url: wrongRootURL, retryToken: token),
            ThreatRemediationRequest(
                requestID: UUID(), relatedCleaningRequestID: UUID(),
                url: plist, retryToken: fabricated),
        ]

        let rejected = await service.remediate(
            retryRequests,
            operationID: UUID(),
            parentID: UUID())

        XCTAssertEqual(rejected.payload.items.map(\.requestID), retryRequests.map(\.requestID))
        for item in rejected.payload.items {
            let issue = try failedIssue(item.disposition)
            XCTAssertEqual(issue.code, "threat.remediation.retryToken.invalid")
            XCTAssertEqual(issue.category, .validation)
            XCTAssertEqual(issue.recovery, .manualAction)
            XCTAssertFalse(issue.retryable)
            XCTAssertEqual(issue.subjectID, item.requestID.uuidString)
            XCTAssertEqual(item.mutation, .none)
        }
        XCTAssertEqual(labels.readCount, 1)
        let controllerCalls = await controller.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
    }

    func testBootoutTimeoutIsRetryablePossiblyChangedAndCarriesBoundToken() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let request = request(plist)
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: StubLaunchAgentController(results: [.timedOut]),
            postcondition: StubPostcondition(states: [.loaded]))

        let result = await service.remediate(
            [request],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        let issue = try failedIssue(item.disposition)
        XCTAssertEqual(issue.code, "threat.remediation.bootout.timeout")
        XCTAssertEqual(issue.subjectID, request.requestID.uuidString)
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(item.mutation, .possiblyChanged)
        XCTAssertEqual(item.retryToken?.validatedLabel, "com.xico.agent")
        XCTAssertEqual(item.retryToken?.rootRelativeIdentity, "agent.plist")
    }

    func testBootoutCancellationAfterStartIsCancelledPossiblyChangedWithBoundIssue() async throws {
        let fixture = try TemporaryLaunchAgents()
        let plist = try fixture.makePlist("agent.plist", label: "com.xico.agent")
        let request = request(plist)
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: StubLaunchAgentController(results: [
                .cancelled(processStarted: true)
            ]),
            postcondition: StubPostcondition(states: [.loaded]))

        let result = await service.remediate(
            [request],
            operationID: UUID(),
            parentID: UUID())

        let item = try XCTUnwrap(result.payload.items.first)
        guard case let .cancelled(issue?) = item.disposition else {
            return XCTFail("expected a bound cancelled fact")
        }
        XCTAssertEqual(issue.code, "threat.remediation.bootout.cancelled")
        XCTAssertEqual(issue.subjectID, request.requestID.uuidString)
        XCTAssertTrue(issue.retryable)
        XCTAssertEqual(item.mutation, .possiblyChanged)
        XCTAssertNotNil(item.retryToken)
        XCTAssertEqual(result.outcome.status, .cancelled)
        XCTAssertEqual(result.outcome.mutation, .possiblyChanged)
    }

    func testBoundedProcessRunnerTimesOutAndReturnsWithoutHanging() async {
        let runner = LaunchctlProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeoutNanoseconds: 30_000_000,
            pollNanoseconds: 2_000_000,
            terminationGraceNanoseconds: 30_000_000)
        let startedAt = Date()

        let result = await runner.run(["5"])

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testBoundedProcessRunnerCancellationTerminatesAndReaps() async throws {
        let runner = LaunchctlProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeoutNanoseconds: 5_000_000_000,
            pollNanoseconds: 2_000_000,
            terminationGraceNanoseconds: 30_000_000)
        let startedAt = Date()
        let task = Task { await runner.run(["5"]) }
        try await Task.sleep(nanoseconds: 30_000_000)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .cancelled(processStarted: true))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testProcessRunnerHardDeadlineSignalsExactlyOnceAndTransfersReaping() async {
        let driver = NeverExitingLaunchctlProcessDriver(pid: 42424)
        let timing = ReadAdvancingLaunchctlProcessTiming(now: 100, step: 6)
        let runner = LaunchctlProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/ignored"),
            timeoutNanoseconds: 10,
            pollNanoseconds: 2,
            terminationGraceNanoseconds: 10,
            killReapDeadlineNanoseconds: 10,
            driver: driver,
            timing: timing)
        let startedAt = Date()

        let result = await runner.run(["ignored"])

        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertEqual(driver.spawnCount, 1)
        XCTAssertEqual(driver.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(driver.transferredPIDs, [42424])
        XCTAssertGreaterThanOrEqual(driver.pollCount, 3)
    }

    func testCancellationPreservesCompletedItemAndCancelsEveryRemainder() async throws {
        let fixture = try TemporaryLaunchAgents()
        let urls = try ["first.plist", "second.plist", "third.plist"]
            .map(fixture.makeFile)
        let requests = urls.map(request)
        let controller = BlockingLaunchAgentController()
        let postcondition = StubPostcondition(states: [.loaded, .notLoaded])
        let service = remediation(
            root: fixture.root,
            labelReader: StubLabelReader(defaultResult: .label("com.xico.agent")),
            controller: controller,
            postcondition: postcondition)
        let operationID = UUID()
        let parentID = UUID()

        let task = Task {
            await service.remediate(
                requests,
                operationID: operationID,
                parentID: parentID)
        }
        await controller.waitUntilInvoked()
        task.cancel()
        await controller.release()
        let result = await task.value

        XCTAssertEqual(result.payload.items.map(\.requestID), requests.map(\.requestID))
        XCTAssertEqual(result.payload.items.first?.disposition, .succeeded)
        XCTAssertEqual(result.payload.items.first?.mutation, .changed)
        for item in result.payload.items.dropFirst() {
            guard case .cancelled(nil) = item.disposition else {
                return XCTFail("Expected cancelled(nil), got \(item.disposition)")
            }
            XCTAssertEqual(item.mutation, .none)
        }
        XCTAssertEqual(result.outcome.id, operationID)
        XCTAssertEqual(result.outcome.parentID, parentID)
        XCTAssertEqual(result.outcome.status, .cancelled)
        XCTAssertEqual(result.outcome.counts.succeeded, 1)
        XCTAssertEqual(result.outcome.counts.cancelled, 2)
        XCTAssertEqual(result.outcome.mutation, .changed)
        let controllerCalls = await controller.recordedCalls()
        let postconditionCalls = await postcondition.recordedCalls()
        XCTAssertEqual(controllerCalls.count, 1)
        XCTAssertEqual(postconditionCalls.count, 2)
    }

    private func remediation(
        root: URL,
        labelReader: some LaunchAgentLabelReading,
        controller: some LaunchAgentControlling,
        postcondition: some LaunchAgentPostconditionChecking,
        retryAuthorizationLifetimeNanoseconds: UInt64 = 300_000_000_000,
        retryAuthorizationCapacity: Int = 1_024,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> ThreatRemediation {
        ThreatRemediation(
            root: root,
            uid: 4242,
            labelReader: labelReader,
            controller: controller,
            postcondition: postcondition,
            retryAuthorizationLifetimeNanoseconds:
                retryAuthorizationLifetimeNanoseconds,
            retryAuthorizationCapacity: retryAuthorizationCapacity,
            monotonicNow: monotonicNow)
    }

    private func request(_ url: URL) -> ThreatRemediationRequest {
        ThreatRemediationRequest(
            requestID: UUID(),
            relatedCleaningRequestID: UUID(),
            url: url)
    }

    private func skippedIssue(
        _ disposition: OperationDisposition
    ) throws -> OperationIssue {
        guard case let .skipped(issue) = disposition else {
            throw UnexpectedDisposition(disposition)
        }
        return issue
    }

    private func failedIssue(
        _ disposition: OperationDisposition
    ) throws -> OperationIssue {
        guard case let .failed(issue) = disposition else {
            throw UnexpectedDisposition(disposition)
        }
        return issue
    }
}

private struct UnexpectedDisposition: Error {
    let disposition: OperationDisposition
    init(_ disposition: OperationDisposition) { self.disposition = disposition }
}

private final class TemporaryLaunchAgents: @unchecked Sendable {
    private let base: URL
    let root: URL
    private let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("xico-threat-remediation-\(UUID().uuidString)",
                                  isDirectory: true)
        root = base.appendingPathComponent("LaunchAgents", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func makeFile(_ name: String) throws -> URL {
        try makeFile(name, in: root)
    }

    func makeFile(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func makeFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func makeOutsideFile(_ name: String) throws -> URL {
        try makeFile(name, in: outside)
    }

    func makePlist(_ name: String, label: String) throws -> URL {
        try makeFile(name, data: Self.plistData(label: label))
    }

    func makeOutsidePlist(_ name: String, label: String) throws -> URL {
        let url = outside.appendingPathComponent(name)
        try Self.plistData(label: label).write(to: url)
        return url
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        return url
    }

    func makeSymlink(_ name: String, destination: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: destination)
        return url
    }

    func makeRootSymlink(_ name: String) throws -> URL {
        let url = root.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: root)
        return url
    }

    func replaceFileWithSymlink(_ url: URL, destination: URL) throws {
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: destination)
    }

    func replaceRootWithFreshDirectory() throws {
        let moved = base.appendingPathComponent("LaunchAgents-original", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false)
    }

    private static func plistData(label: String) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: ["Label": label],
            format: .xml,
            options: 0)
    }
}

private final class StubLabelReader: LaunchAgentLabelReading, @unchecked Sendable {
    private let lock = NSLock()
    private let defaultResult: LaunchAgentLabelReadResult
    private var payloads: [Data] = []

    init(defaultResult: LaunchAgentLabelReadResult) {
        self.defaultResult = defaultResult
    }

    func readLabel(from data: Data) -> LaunchAgentLabelReadResult {
        lock.withLock { payloads.append(data) }
        return defaultResult
    }

    var readCount: Int { lock.withLock { payloads.count } }
}

private final class MutatingPropertyListLabelReader: LaunchAgentLabelReading, @unchecked Sendable {
    private let lock = NSLock()
    private let mutation: @Sendable () -> Void
    private var count = 0

    init(mutation: @escaping @Sendable () -> Void) {
        self.mutation = mutation
    }

    func readLabel(from data: Data) -> LaunchAgentLabelReadResult {
        lock.withLock { count += 1 }
        mutation()
        return PropertyListLaunchAgentLabelReader().readLabel(from: data)
    }

    var readCount: Int { lock.withLock { count } }
}

private struct LaunchAgentCall: Equatable, Sendable {
    let uid: uid_t
    let label: String
}

private actor StubLaunchAgentController: LaunchAgentControlling {
    private var results: [LaunchAgentBootoutResult]
    private var calls: [LaunchAgentCall] = []

    init(results: [LaunchAgentBootoutResult]) {
        self.results = results
    }

    func bootout(label: String, uid: uid_t) async -> LaunchAgentBootoutResult {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        return results.isEmpty ? .notInvoked : results.removeFirst()
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private actor StubPostcondition: LaunchAgentPostconditionChecking {
    private var states: [LaunchAgentLoadState]
    private var calls: [LaunchAgentCall] = []

    init(states: [LaunchAgentLoadState]) {
        self.states = states
    }

    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        return states.isEmpty ? .unknown : states.removeFirst()
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private struct TimedLoadState: Sendable {
    let state: LaunchAgentLoadState
    let advance: UInt64
}

private actor ClockAdvancingPostcondition: LaunchAgentPostconditionChecking {
    private let clock: TestMonotonicClock
    private var steps: [TimedLoadState]
    private var calls: [LaunchAgentCall] = []

    init(clock: TestMonotonicClock, steps: [TimedLoadState]) {
        self.clock = clock
        self.steps = steps
    }

    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        guard !steps.isEmpty else { return .unknown }
        let next = steps.removeFirst()
        clock.advance(by: next.advance)
        return next.state
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private actor BlockingRetryPostcondition: LaunchAgentPostconditionChecking {
    private var calls: [LaunchAgentCall] = []
    private var retryProbeStarted = false
    private var retryProbeReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        if calls.count == 1 { return .loaded }

        retryProbeStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }
        if !retryProbeReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .notLoaded
    }

    func waitUntilRetryProbeStarts() async {
        guard !retryProbeStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseRetryProbe() {
        retryProbeReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private actor BlockingInitialPostcondition: LaunchAgentPostconditionChecking {
    private var calls: [LaunchAgentCall] = []
    private var probeStarted = false
    private var probeReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func loadState(label: String, uid: uid_t) async -> LaunchAgentLoadState {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        probeStarted = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }
        if !probeReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .loaded
    }

    func waitUntilProbeStarts() async {
        guard !probeStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseProbe() {
        probeReleased = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private actor BlockingLaunchAgentController: LaunchAgentControlling {
    private var calls: [LaunchAgentCall] = []
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func bootout(label: String, uid: uid_t) async -> LaunchAgentBootoutResult {
        calls.append(LaunchAgentCall(uid: uid, label: label))
        let waiters = invocationWaiters
        invocationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .invoked
    }

    func waitUntilInvoked() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { invocationWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordedCalls() -> [LaunchAgentCall] { calls }
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(now: UInt64) {
        value = now
    }

    func read() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by delta: UInt64) {
        lock.withLock {
            value = value.addingReportingOverflow(delta).overflow
                ? UInt64.max
                : value + delta
        }
    }
}

private final class NeverExitingLaunchctlProcessDriver:
    LaunchctlProcessDriving, @unchecked Sendable
{
    private let lock = NSLock()
    private let pid: pid_t
    private var storedSpawnCount = 0
    private var storedPollCount = 0
    private var storedSignals: [Int32] = []
    private var storedTransferredPIDs: [pid_t] = []

    init(pid: pid_t) {
        self.pid = pid
    }

    func spawn(executableURL: URL, arguments: [String]) -> pid_t? {
        lock.withLock { storedSpawnCount += 1 }
        return pid
    }

    func poll(_ pid: pid_t) -> LaunchctlProcessPollResult {
        lock.withLock { storedPollCount += 1 }
        return .running
    }

    func send(signal: Int32, to pid: pid_t) {
        lock.withLock { storedSignals.append(signal) }
    }

    func transferToBestEffortReaper(_ pid: pid_t) {
        lock.withLock { storedTransferredPIDs.append(pid) }
    }

    var spawnCount: Int { lock.withLock { storedSpawnCount } }
    var pollCount: Int { lock.withLock { storedPollCount } }
    var signals: [Int32] { lock.withLock { storedSignals } }
    var transferredPIDs: [pid_t] { lock.withLock { storedTransferredPIDs } }
}

private final class ReadAdvancingLaunchctlProcessTiming:
    LaunchctlProcessTiming, @unchecked Sendable
{
    private let lock = NSLock()
    private var value: UInt64
    private let step: UInt64

    init(now: UInt64, step: UInt64) {
        value = now
        self.step = step
    }

    func now() -> UInt64 {
        lock.withLock {
            let current = value
            value = value.addingReportingOverflow(step).overflow
                ? UInt64.max
                : value + step
            return current
        }
    }

    func sleep(nanoseconds: UInt64) async {
        await Task.yield()
    }
}
