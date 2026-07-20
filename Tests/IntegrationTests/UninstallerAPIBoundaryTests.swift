import Foundation
import XCTest

final class UninstallerAPIBoundaryTests: XCTestCase {
    private struct CompileResult {
        let status: Int32
        let output: String
    }

    func testNormalImportKeepsOnlySafeUninstallSurfaceReachable() throws {
        let positive = try compile("""
            import Domain
            import Infrastructure

            func inspectPublicSurface(
                service: UninstallerService,
                environment: XicoEnvironment,
                batch: UninstallBatch
            ) {
                _ = service
                _ = environment
                _ = batch.mode
                _ = EvidenceFingerprint.none
            }
            """)
        XCTAssertEqual(positive.status, 0, positive.output)

        let inaccessibleClients: [(String, Bool, String)] = [
            ("domain raw issuer and clock", true, """
                import Foundation
                import Domain
                import Infrastructure
                func bypass(sampler: any IdentitySampler) {
                    let ledger = AuthorizationLedger()
                    let issuer = DestructiveOperationIssuer(
                        sampler: sampler, ledger: ledger, wallNow: { Date() })
                    _ = issuer.prepare(kind: .uninstall, targets: [])
                }
                """),
            ("raw preparation and prepared payload read", true, """
                import Domain
                import Infrastructure
                func bypass(
                    service: UninstallerService,
                    batch: UninstallBatch,
                    issuer: DestructiveOperationIssuer
                ) throws {
                    let prepared = try service.prepareUninstallExecution(
                        from: batch, using: issuer)
                    _ = prepared.plan
                }
                """),
            ("prepared construction", true, """
                import Infrastructure
                let preparedType = PreparedUninstallExecution.self
                """),
            ("dedicated uninstall execution SPI", true, """
                import Domain
                let requestType = UninstallExecutionRequest.self
                let permitType = UninstallExecutionPermit.self
                """),
            ("malformed uninstall fact factory SPI", true, """
                import Domain
                let occurrenceType = UninstallMalformedOccurrence.self
                let factory = CleaningReport.uninstallMalformed
                """),
            ("confirmation construction and internals", true, """
                import Infrastructure
                func forge(batch: UninstallBatch, service: UninstallerService) {
                    let value = UninstallConfirmation(batch: batch, service: service)
                    _ = value.batch
                    _ = value.service
                }
                """),
            ("claim clock hooks and injected controller", true, """
                import Domain
                import Infrastructure
                func inject(service: UninstallerService,
                            issuer: DestructiveOperationIssuer) {
                    _ = SystemUninstallTrustedClock()
                    _ = UninstallCapabilityHooks()
                    _ = UninstallBatchClaimToken.self
                    _ = UninstallCapabilityController(
                        service: service, issuer: issuer,
                        clock: SystemUninstallTrustedClock())
                }
                """),
            ("batch construction", false, """
                import Foundation
                import Infrastructure
                func forge(app: InstalledApp) {
                    _ = UninstallBatch(
                        issuanceID: UUID(), batchID: UUID(), app: app,
                        mode: .uninstallApp, candidates: [])
                }
                """),
            ("environment capability access and injection", false, """
                import Domain
                import Infrastructure
                func inspect(environment: XicoEnvironment) {
                    _ = environment.uninstallCapability
                    _ = environment.uninstaller
                }
                func inject(fs: any FileSystemService,
                            safety: any SafetyEngine,
                            definitions: DefinitionsLibrary,
                            service: UninstallerService) {
                    _ = XicoEnvironment(
                        fs: fs, safety: safety, definitions: definitions,
                        uninstaller: service)
                }
                """),
            ("evidence fingerprint construction", false, """
                import Domain
                let fingerprint = EvidenceFingerprint(
                    sha256: [UInt8](repeating: 1, count: 32))
                """)
        ]

        for (name, allowsHiddenSymbol, source) in inaccessibleClients {
            let result = try compile(source)
            XCTAssertNotEqual(result.status, 0, "\(name) unexpectedly compiled")
            XCTAssertFalse(result.output.localizedCaseInsensitiveContains("no such module"),
                           "\(name) did not reach access checking:\n\(result.output)")
            let explicitlyInaccessible = result.output.localizedCaseInsensitiveContains(
                "inaccessible") || result.output.localizedCaseInsensitiveContains(
                    "protection level")
            let hiddenFromNormalImport = allowsHiddenSymbol
                && result.output.localizedCaseInsensitiveContains("cannot find")
                && result.output.localizedCaseInsensitiveContains("in scope")
            XCTAssertTrue(explicitlyInaccessible || hiddenFromNormalImport,
                "\(name) must fail because of access control:\n\(result.output)")
        }
    }

    func testFeaturesPackageCannotMintRawCapabilityOrInjectEnvironment() throws {
        let packagePositive = try compile("""
            import Domain
            import Infrastructure

            func useApprovedRoute(router: any UninstallCapabilityRouting,
                                  confirmation: UninstallConfirmation) async throws {
                _ = try await router.execute(confirmation: confirmation)
            }
            """, packageName: "xicoapp")
        XCTAssertEqual(packagePositive.status, 0,
                       "the package-name harness must see the approved Features surface:\n"
                        + packagePositive.output)

        let rawCapability = try compile("""
            import Foundation
            import Domain
            import Infrastructure

            struct FeatureSampler: IdentitySampler {
                func sample(_ path: String) -> LocalFileIdentity? {
                    LocalFileIdentity(device: 1, inode: 2, mode: 0, size: 0,
                                      mtimeNanoseconds: 0, hardLinkCount: 1)
                }
            }

            func bypass() async {
                let fingerprint = EvidenceFingerprint(
                    sha256: [UInt8](repeating: 1, count: 32))!
                let request = TargetRequest(
                    canonicalPath: "/tmp/feature-bypass",
                    recoverability: .trashRestorable,
                    riskLevel: .low,
                    attribution: .verifiedAppBody,
                    evidenceFingerprint: fingerprint)
                let ledger = AuthorizationLedger()
                let issuer = DestructiveOperationIssuer(
                    sampler: FeatureSampler(), ledger: ledger, wallNow: { Date() })
                let plan = issuer.prepare(kind: .uninstall, targets: [request])
                guard let authorization = issuer.authorize(plan) else { return }
                _ = await issuer.execute(plan, authorization: authorization) { 1 }
            }
            """, packageName: "xicoapp")
        XCTAssertNotEqual(rawCapability.status, 0,
                          "Features-package code unexpectedly minted/executed a raw capability")
        XCTAssertFalse(rawCapability.output.localizedCaseInsensitiveContains("no such module"),
                       rawCapability.output)

        let environmentInjection = try compile("""
            import Domain
            import Infrastructure

            func inject(fs: any FileSystemService,
                        safety: any SafetyEngine,
                        definitions: DefinitionsLibrary,
                        service: UninstallerService) {
                _ = XicoEnvironment(
                    fs: fs, safety: safety, definitions: definitions,
                    uninstaller: service)
            }
            """, packageName: "xicoapp")
        XCTAssertNotEqual(environmentInjection.status, 0,
                          "Features-package code unexpectedly injected an uninstall service")
        XCTAssertFalse(environmentInjection.output.localizedCaseInsensitiveContains("no such module"),
                       environmentInjection.output)

        let payloadSubstitution = try compile("""
            import Domain
            import Infrastructure

            func substitute(router: any UninstallCapabilityRouting,
                            confirmation: UninstallConfirmation,
                            unrelatedReport: CleaningReport) async throws {
                _ = try await router.execute(confirmation: confirmation) { _ in
                    unrelatedReport
                }
            }
            """, packageName: "xicoapp")
        XCTAssertNotEqual(payloadSubstitution.status, 0,
                          "Features-package code unexpectedly supplied an unrelated payload")
        XCTAssertFalse(payloadSubstitution.output.localizedCaseInsensitiveContains("no such module"),
                       payloadSubstitution.output)

        let productionPermit = try compile("""
            @_spi(XicoUninstallExecution) import Domain
            import Infrastructure

            func steal(environment: XicoEnvironment) {
                _ = UninstallExecutionPermitToken()
                _ = environment.uninstallExecutionPermit
            }
            """, packageName: "xicoapp")
        XCTAssertNotEqual(productionPermit.status, 0,
                          "Features-package code unexpectedly obtained the production permit")
        XCTAssertFalse(productionPermit.output.lowercased().contains("no such module"),
                       productionPermit.output)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                       isDirectory: true)
        let features = root.appendingPathComponent("Sources/Features", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: features,
            includingPropertiesForKeys: nil)
        let offenders = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "swift"
                && ((try? String(contentsOf: $0, encoding: .utf8)) ?? "")
                    .contains("@_spi(XicoUninstallExecution)")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "Features must not opt into the uninstall execution SPI: \(offenders)")
    }

    private func compile(_ source: String,
                         packageName: String? = nil) throws -> CompileResult {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                       isDirectory: true)
        #if arch(arm64)
        let buildTriple = "arm64-apple-macosx"
        let target = "arm64-apple-macosx14.0"
        #else
        let buildTriple = "x86_64-apple-macosx"
        let target = "x86_64-apple-macosx14.0"
        #endif
        let modules = root.appendingPathComponent(
            ".build/\(buildTriple)/debug/Modules", isDirectory: true)
        let debug = modules.deletingLastPathComponent()
        let moduleMaps = ["CProcessBatch", "CSensors"].map {
            debug.appendingPathComponent("\($0).build/module.modulemap")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path), modules.path)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "xico-uninstaller-api-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Client.swift")
        try Data(source.utf8).write(to: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = [
            "swiftc", "-typecheck", "-target", target,
            "-module-cache-path", "/private/tmp/xico-api-boundary-module-cache",
            "-I", modules.path
        ]
        if let packageName {
            arguments.append(contentsOf: ["-package-name", packageName])
        }
        for moduleMap in moduleMaps {
            XCTAssertTrue(FileManager.default.fileExists(atPath: moduleMap.path), moduleMap.path)
            arguments.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(moduleMap.path)"])
        }
        arguments.append(sourceURL.path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CompileResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}
