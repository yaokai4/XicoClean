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
              scripts/sign_components.swift --generate-keypair
              XICO_COMPONENTS_PRIVATE_KEY=<base64> scripts/sign_components.swift --input components.json --output components.signed.json --key-id components-v1
              scripts/sign_components.swift --self-test
            """
        case .missing(let name): return "缺少参数：\(name)"
        }
    }
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func generateKeypair() {
    let key = Curve25519.Signing.PrivateKey()
    print("private=\(key.rawRepresentation.base64EncodedString())")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func sign(input: URL, output: URL, keyID: String, privateKeyBase64: String) throws {
    guard let privateData = Data(base64Encoded: privateKeyBase64) else {
        throw ToolError.missing("XICO_COMPONENTS_PRIVATE_KEY")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    let payload = try Data(contentsOf: input)
    // 签名前先保证输入至少是合法 JSON；业务字段仍由客户端的严格 schema/时效/URL 校验负责。
    _ = try JSONSerialization.jsonObject(with: payload)
    let signature = try key.signature(for: payload)
    let envelope = Envelope(keyID: keyID,
                            payloadBase64: payload.base64EncodedString(),
                            signatureBase64: signature.base64EncodedString())
    let encoded = try JSONEncoder().encode(envelope)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: output, options: .atomic)
    print("signed=\(output.path)")
    print("keyID=\(keyID)")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func selfTest() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("xico-sign-components-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("components.json")
    let output = directory.appendingPathComponent("components.signed.json")
    let now = Int64(Date().timeIntervalSince1970)
    let fixture = """
    {"schemaVersion":1,"sequence":1,"issuedAt":\(now),"expiresAt":\(now + 86400),"components":[{"id":"yt-dlp","version":"self-test","architecture":"universal","downloadURL":"https://example.invalid/yt-dlp","sha256":"\(String(repeating: "a", count: 64))","size":1,"archive":"raw","executableName":"yt-dlp"}]}
    """
    try Data(fixture.utf8).write(to: input)
    let key = Curve25519.Signing.PrivateKey()
    try sign(input: input, output: output, keyID: "self-test",
             privateKeyBase64: key.rawRepresentation.base64EncodedString())
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
        guard let input = value(after: "--input", in: args) else { throw ToolError.missing("--input") }
        guard let output = value(after: "--output", in: args) else { throw ToolError.missing("--output") }
        guard let keyID = value(after: "--key-id", in: args) else { throw ToolError.missing("--key-id") }
        guard let privateKey = ProcessInfo.processInfo.environment["XICO_COMPONENTS_PRIVATE_KEY"] else {
            throw ToolError.missing("XICO_COMPONENTS_PRIVATE_KEY")
        }
        try sign(input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
                 keyID: keyID, privateKeyBase64: privateKey)
    }
} catch let error as ToolError {
    fputs("\(error.description)\n", stderr)
    exit(2)
} catch {
    fputs("error=\(error)\n", stderr)
    exit(1)
}
