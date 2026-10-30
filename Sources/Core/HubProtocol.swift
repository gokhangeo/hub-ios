import Foundation
import Security

/// Mirrors src/protocol.js and public/runtime-config.js of gokhangeo/hub.
enum Hub {
    static let protocolVersion: Int64 = 2
    static let chunkSize = 64 * 1024
    static let maxBufferedAmount: UInt64 = 1024 * 1024
    static let textMaxBytes = 1024 * 1024
    static let maxFileBytes: Int64 = 10 * 1024 * 1024 * 1024
    static let pwaBase = "https://gokhangeo.github.io/hub/"
    static let iceServers = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]
    static let acceptTimeout: TimeInterval = 120

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes
    }

    static func generateCode() -> String {
        var value: UInt32
        repeat {
            let b = randomBytes(4)
            value = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        } while value >= 4_294_000_000
        return "BT-" + String(format: "%06u", value % 1_000_000)
    }

    static func generateSessionKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(randomBytes(16).map { alphabet[Int($0) % alphabet.count] })
    }

    static func transferId() -> String {
        randomBytes(12).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String(randomBytes(11).map { alphabet[Int($0) % alphabet.count] })
    }

    static func digits(_ value: String) -> String {
        String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    static func normalizeCode(_ value: String) -> String? {
        let d = digits(value)
        return d.count == 6 ? "BT-" + d : nil
    }

    static func displayCode(_ code: String) -> String {
        let d = digits(code)
        guard d.count == 6 else { return "" }
        return String(d.prefix(3)) + " " + String(d.suffix(3))
    }

    static func isValidKey(_ key: String) -> Bool {
        key.range(of: "^[A-HJ-NP-Z2-9]{16}$", options: .regularExpression) != nil
    }

    /// Same link the PWA puts in its QR: ?receive=BT-123456&k=KEY
    static func receiveLink(code: String, key: String) -> String {
        var comps = URLComponents(string: pwaBase)!
        comps.queryItems = [URLQueryItem(name: "receive", value: code), URLQueryItem(name: "k", value: key)]
        return comps.url!.absoluteString
    }

    /// Accepts a full link (receive= or join=, optional k=) or a bare code.
    static func parse(_ text: String) -> (code: String, key: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed), let items = comps.queryItems, !items.isEmpty {
            let raw = items.first(where: { $0.name == "receive" })?.value ?? items.first(where: { $0.name == "join" })?.value ?? ""
            if let code = normalizeCode(raw) {
                let key = items.first(where: { $0.name == "k" })?.value ?? ""
                return (code, isValidKey(key) ? key : "")
            }
        }
        let compact = trimmed.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let body = compact.hasPrefix("BT") ? String(compact.dropFirst(2)) : compact
        if body.count == 6, body.allSatisfy({ $0.isNumber }) { return ("BT-" + body, "") }
        return nil
    }

    static func sanitizeFilename(_ value: String) -> String {
        var name = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(String.init).joined()
        for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"] { name = name.replacingOccurrences(of: ch, with: "_") }
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "dosya" }
        return String(name.prefix(180))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
