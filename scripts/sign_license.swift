#!/usr/bin/env swift
import Foundation
import CryptoKit

struct Payload: Codable {
    let licenseID: String
    let productID: String
    let customerName: String
    let issuedAt: Date
    let expiresAt: Date?
    let maxMajorVersion: Int
}

struct Envelope: Codable {
    let keyID: String
    let payloadBase64: String
    let signatureBase64: String
}

enum ToolError: Error, CustomStringConvertible {
    case usage
    case missing(String)
    case invalidDate(String)

    var description: String {
        switch self {
        case .usage:
            return """
            用法:
              scripts/sign_license.swift --generate-keypair
              XICO_LICENSE_PRIVATE_KEY=<base64> scripts/sign_license.swift --license-id id --customer "Name" --output license.xico-license --key-id release-v1 [--product-id com.xico.app] [--expires-at 2027-12-31] [--max-major-version 1]
              scripts/sign_license.swift --self-test
            """
        case let .missing(name):
            return "缺少参数：\(name)"
        case let .invalidDate(value):
            return "日期格式无效：\(value)，请使用 YYYY-MM-DD 或 ISO8601 时间"
        }
    }
}

func value(after flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func generateKeypair() {
    let key = Curve25519.Signing.PrivateKey()
    print("private=\(key.rawRepresentation.base64EncodedString())")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func parseDate(_ raw: String) throws -> Date {
    let fullDate = ISO8601DateFormatter()
    fullDate.formatOptions = [.withFullDate]
    if let date = fullDate.date(from: raw) { return date }
    if let date = ISO8601DateFormatter().date(from: raw) { return date }
    throw ToolError.invalidDate(raw)
}

func sign(payload: Payload, output: URL, keyID: String, privateKeyBase64: String) throws {
    guard let privateData = Data(base64Encoded: privateKeyBase64) else {
        throw ToolError.missing("XICO_LICENSE_PRIVATE_KEY")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = try encoder.encode(payload)
    let signature = try key.signature(for: payloadData)
    let envelope = Envelope(
        keyID: keyID,
        payloadBase64: payloadData.base64EncodedString(),
        signatureBase64: signature.base64EncodedString()
    )
    let data = try JSONEncoder().encode(envelope)
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: output, options: .atomic)
    print("signed=\(output.path)")
    print("licenseID=\(payload.licenseID)")
    print("customer=\(payload.customerName)")
    print("keyID=\(keyID)")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func selfTest() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("xico-sign-license-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    let output = tmp.appendingPathComponent("license.xico-license")
    let payload = Payload(
        licenseID: "self-test",
        productID: "com.xico.app",
        customerName: "Self Test",
        issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        maxMajorVersion: 1
    )
    try sign(payload: payload, output: output, keyID: "self-test", privateKeyBase64: key.rawRepresentation.base64EncodedString())
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: output))
    guard let payloadData = Data(base64Encoded: envelope.payloadBase64),
          let signature = Data(base64Encoded: envelope.signatureBase64),
          key.publicKey.isValidSignature(signature, for: payloadData) else {
        throw ToolError.missing("self-test verification")
    }
    let decoded = try JSONDecoder().decode(Payload.self, from: payloadData)
    guard decoded.licenseID == "self-test" else {
        throw ToolError.missing("self-test payload")
    }
    print("self-test=ok")
}

do {
    let args = CommandLine.arguments
    if args.contains("--generate-keypair") {
        generateKeypair()
    } else if args.contains("--self-test") {
        try selfTest()
    } else {
        guard let licenseID = value(after: "--license-id", in: args) else { throw ToolError.missing("--license-id") }
        guard let customer = value(after: "--customer", in: args) else { throw ToolError.missing("--customer") }
        guard let outputPath = value(after: "--output", in: args) else { throw ToolError.missing("--output") }
        guard let keyID = value(after: "--key-id", in: args) else { throw ToolError.missing("--key-id") }
        guard let privateKey = ProcessInfo.processInfo.environment["XICO_LICENSE_PRIVATE_KEY"] else {
            throw ToolError.missing("XICO_LICENSE_PRIVATE_KEY")
        }
        let productID = value(after: "--product-id", in: args) ?? "com.xico.app"
        let major = Int(value(after: "--max-major-version", in: args) ?? "1") ?? 1
        let expiresAt = try value(after: "--expires-at", in: args).map(parseDate)
        let payload = Payload(
            licenseID: licenseID,
            productID: productID,
            customerName: customer,
            issuedAt: Date(),
            expiresAt: expiresAt,
            maxMajorVersion: major
        )
        try sign(
            payload: payload,
            output: URL(fileURLWithPath: outputPath),
            keyID: keyID,
            privateKeyBase64: privateKey
        )
    }
} catch let error as ToolError {
    fputs("\(error.description)\n", stderr)
    exit(2)
} catch {
    fputs("error=\(error)\n", stderr)
    exit(1)
}
