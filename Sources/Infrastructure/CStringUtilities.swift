import Foundation

func xicoString(fromNullTerminated bytes: [CChar]) -> String {
    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
    let utf8 = bytes[..<end].map { UInt8(bitPattern: $0) }
    return String(decoding: utf8, as: UTF8.self)
}
