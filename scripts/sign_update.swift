#!/usr/bin/env swift
import Foundation
import CryptoKit

enum ToolError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing(let value): return "缺少参数：\(value)"
        case .invalid(let value): return "参数无效：\(value)"
        }
    }
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func descriptor(version: String, downloadURL: String, sha256: String?) throws -> Data {
    guard !version.isEmpty else { throw ToolError.invalid("--version") }
    guard let url = URL(string: downloadURL), url.scheme?.lowercased() == "https", url.host != nil else {
        throw ToolError.invalid("--url 必须是 HTTPS URL")
    }
    let normalizedHash: String?
    if let sha256, !sha256.isEmpty {
        let value = sha256.lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw ToolError.invalid("--sha256")
        }
        normalizedHash = value
    } else {
        normalizedHash = nil
    }
    let text = version + "\n" + url.absoluteString + (normalizedHash.map { "\n" + $0 } ?? "")
    return Data(text.utf8)
}

func generateKeypair() {
    let key = Curve25519.Signing.PrivateKey()
    print("private=\(key.rawRepresentation.base64EncodedString())")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func sign(arguments: [String], privateKeyBase64: String) throws {
    guard let version = value(after: "--version", in: arguments) else { throw ToolError.missing("--version") }
    guard let url = value(after: "--url", in: arguments) else { throw ToolError.missing("--url") }
    let sha256 = value(after: "--sha256", in: arguments)
    guard let keyData = Data(base64Encoded: privateKeyBase64) else {
        throw ToolError.invalid("XICO_UPDATE_PRIVATE_KEY")
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let message = try descriptor(version: version, downloadURL: url, sha256: sha256)
    let signature = try key.signature(for: message)
    print("signature=\(signature.base64EncodedString())")
    print("public=\(key.publicKey.rawRepresentation.base64EncodedString())")
}

func selfTest() throws {
    let key = Curve25519.Signing.PrivateKey()
    let message = try descriptor(
        version: "1.2.3",
        downloadURL: "https://mac.xicoai.com/api/download/xico-clean",
        sha256: String(repeating: "a", count: 64)
    )
    let signature = try key.signature(for: message)
    guard key.publicKey.isValidSignature(signature, for: message) else {
        throw ToolError.invalid("self-test verification")
    }
    print("self-test=ok")
}

do {
    let arguments = CommandLine.arguments
    if arguments.contains("--generate-keypair") {
        generateKeypair()
    } else if arguments.contains("--self-test") {
        try selfTest()
    } else {
        guard let privateKey = ProcessInfo.processInfo.environment["XICO_UPDATE_PRIVATE_KEY"] else {
            throw ToolError.missing("XICO_UPDATE_PRIVATE_KEY")
        }
        try sign(arguments: arguments, privateKeyBase64: privateKey)
    }
} catch let error as ToolError {
    fputs("\(error.description)\n", stderr)
    exit(2)
} catch {
    fputs("error=\(error)\n", stderr)
    exit(1)
}
