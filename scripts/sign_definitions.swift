#!/usr/bin/env swift
import Foundation
import CryptoKit

struct Envelope: Codable {
    let keyID: String
    let payloadBase64: String
    let signatureBase64: String
}

enum ToolError: Error, CustomStringConvertible {
    case usage
    case missing(String)

    var description: String {
        switch self {
        case .usage:
            return """
            用法:
              scripts/sign_definitions.swift --generate-keypair
              XICO_DEFINITIONS_PRIVATE_KEY=<base64> scripts/sign_definitions.swift --input definitions.json --output definitions.signed.json --key-id release-v1
              scripts/sign_definitions.swift --self-test
            """
        case let .missing(name):
            return "缺少参数：\(name)"
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

func sign(input: URL, output: URL, keyID: String, privateKeyBase64: String) throws {
    guard let privateData = Data(base64Encoded: privateKeyBase64) else { throw ToolError.missing("XICO_DEFINITIONS_PRIVATE_KEY") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    let payload = try Data(contentsOf: input)
    let signature = try key.signature(for: payload)
    let envelope = Envelope(
        keyID: keyID,
        payloadBase64: payload.base64EncodedString(),
        signatureBase64: signature.base64EncodedString()
    )
    let data = try JSONEncoder().encode(envelope)
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: output, options: .atomic)
    print("signed=\(output.path)")
    print("keyID=\(keyID)")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func selfTest() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("xico-sign-definitions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let input = tmp.appendingPathComponent("definitions.json")
    let output = tmp.appendingPathComponent("definitions.signed.json")
    try #"{"version":999,"definitions":[{"id":"x","category":"system-junk","title":"x","description":"x","paths":["~/Library/Caches/x"]}]}"#
        .data(using: .utf8)!
        .write(to: input)
    let key = Curve25519.Signing.PrivateKey()
    try sign(input: input, output: output, keyID: "self-test", privateKeyBase64: key.rawRepresentation.base64EncodedString())
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: output))
    guard let payload = Data(base64Encoded: envelope.payloadBase64),
          let signature = Data(base64Encoded: envelope.signatureBase64),
          key.publicKey.isValidSignature(signature, for: payload) else {
        throw ToolError.missing("self-test verification")
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
        guard let inputPath = value(after: "--input", in: args) else { throw ToolError.missing("--input") }
        guard let outputPath = value(after: "--output", in: args) else { throw ToolError.missing("--output") }
        guard let keyID = value(after: "--key-id", in: args) else { throw ToolError.missing("--key-id") }
        guard let privateKey = ProcessInfo.processInfo.environment["XICO_DEFINITIONS_PRIVATE_KEY"] else {
            throw ToolError.missing("XICO_DEFINITIONS_PRIVATE_KEY")
        }
        try sign(
            input: URL(fileURLWithPath: inputPath),
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
