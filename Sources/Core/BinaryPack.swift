import Foundation

/// A value in PeerJS's BinaryPack format (peerjs-js-binarypack 2.x, used by
/// `serialization: 'binary'`). It looks like MessagePack but strings use 0xb0/0xd8/0xd9,
/// so it has to be mirrored byte for byte to talk to the HUB PWA.
indirect enum PackValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([PackValue])
    case map([(String, PackValue)])

    subscript(key: String) -> PackValue? {
        if case .map(let pairs) = self { return pairs.first(where: { $0.0 == key })?.1 }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var data: Data? { if case .binary(let d) = self { return d }; return nil }
    var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int64(d)
        default: return nil
        }
    }
    var isMap: Bool { if case .map = self { return true }; return false }

    static func object(_ pairs: [(String, PackValue?)]) -> PackValue {
        .map(pairs.compactMap { key, value in value.map { (key, $0) } })
    }
}

enum BinaryPack {
    struct DecodeError: Error {}

    // MARK: Packing

    static func pack(_ value: PackValue) -> Data {
        var out = Data()
        out.reserveCapacity(64)
        write(value, into: &out)
        return out
    }

    private static func write(_ value: PackValue, into out: inout Data) {
        switch value {
        case .null: out.append(0xc0)
        case .bool(let b): out.append(b ? 0xc3 : 0xc2)
        case .int(let n): writeInt(n, into: &out)
        case .double(let d):
            if d.rounded() == d && abs(d) < 9.0e15 { writeInt(Int64(d), into: &out); return }
            out.append(0xcb)
            appendUInt(d.bitPattern, bytes: 8, into: &out)
        case .string(let s):
            let bytes = Array(s.utf8)
            let n = bytes.count
            if n <= 0x0f { out.append(UInt8(0xb0 + n)) }
            else if n <= 0xffff { out.append(0xd8); appendUInt(UInt64(n), bytes: 2, into: &out) }
            else { out.append(0xd9); appendUInt(UInt64(n), bytes: 4, into: &out) }
            out.append(contentsOf: bytes)
        case .binary(let d):
            let n = d.count
            if n <= 0x0f { out.append(UInt8(0xa0 + n)) }
            else if n <= 0xffff { out.append(0xda); appendUInt(UInt64(n), bytes: 2, into: &out) }
            else { out.append(0xdb); appendUInt(UInt64(n), bytes: 4, into: &out) }
            out.append(d)
        case .array(let items):
            let n = items.count
            if n <= 0x0f { out.append(UInt8(0x90 + n)) }
            else if n <= 0xffff { out.append(0xdc); appendUInt(UInt64(n), bytes: 2, into: &out) }
            else { out.append(0xdd); appendUInt(UInt64(n), bytes: 4, into: &out) }
            for item in items { write(item, into: &out) }
        case .map(let pairs):
            let n = pairs.count
            if n <= 0x0f { out.append(UInt8(0x80 + n)) }
            else if n <= 0xffff { out.append(0xde); appendUInt(UInt64(n), bytes: 2, into: &out) }
            else { out.append(0xdf); appendUInt(UInt64(n), bytes: 4, into: &out) }
            for (key, item) in pairs {
                write(.string(key), into: &out)
                write(item, into: &out)
            }
        }
    }

    /// Same branch order as Packer.pack_integer in JS.
    private static func writeInt(_ n: Int64, into out: inout Data) {
        if n >= -0x20 && n <= 0x7f { out.append(UInt8(truncatingIfNeeded: n)) }
        else if n >= 0 && n <= 0xff { out.append(0xcc); out.append(UInt8(n)) }
        else if n >= -0x80 && n <= 0x7f { out.append(0xd0); out.append(UInt8(truncatingIfNeeded: n)) }
        else if n >= 0 && n <= 0xffff { out.append(0xcd); appendUInt(UInt64(n), bytes: 2, into: &out) }
        else if n >= -0x8000 && n <= 0x7fff { out.append(0xd1); appendUInt(UInt64(UInt16(truncatingIfNeeded: n)), bytes: 2, into: &out) }
        else if n >= 0 && n <= 0xffff_ffff { out.append(0xce); appendUInt(UInt64(n), bytes: 4, into: &out) }
        else if n >= -0x8000_0000 && n <= 0x7fff_ffff { out.append(0xd2); appendUInt(UInt64(UInt32(truncatingIfNeeded: n)), bytes: 4, into: &out) }
        else { out.append(0xd3); appendUInt(UInt64(bitPattern: n), bytes: 8, into: &out) }
    }

    private static func appendUInt(_ value: UInt64, bytes: Int, into out: inout Data) {
        for i in stride(from: bytes - 1, through: 0, by: -1) {
            out.append(UInt8(truncatingIfNeeded: value >> (UInt64(i) * 8)))
        }
    }

    // MARK: Unpacking

    static func unpack(_ data: Data) throws -> PackValue {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.value()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func u8() throws -> UInt8 {
            guard index < bytes.count else { throw DecodeError() }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func uint(_ count: Int) throws -> UInt64 {
            guard index + count <= bytes.count else { throw DecodeError() }
            var v: UInt64 = 0
            for i in 0..<count { v = (v << 8) | UInt64(bytes[index + i]) }
            index += count
            return v
        }

        mutating func raw(_ count: Int) throws -> [UInt8] {
            guard count >= 0, index + count <= bytes.count else { throw DecodeError() }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        mutating func value() throws -> PackValue {
            let type = try u8()
            if type < 0x80 { return .int(Int64(type)) }
            if (type ^ 0xe0) < 0x20 { return .int(Int64(type ^ 0xe0) - 0x20) }
            if (type ^ 0xa0) <= 0x0f { return .binary(Data(try raw(Int(type ^ 0xa0)))) }
            if (type ^ 0xb0) <= 0x0f { return .string(String(decoding: try raw(Int(type ^ 0xb0)), as: UTF8.self)) }
            if (type ^ 0x90) <= 0x0f { return try array(Int(type ^ 0x90)) }
            if (type ^ 0x80) <= 0x0f { return try map(Int(type ^ 0x80)) }
            switch type {
            case 0xc0, 0xc1, 0xd4, 0xd5, 0xd6, 0xd7: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xca: return .double(Double(Float(bitPattern: UInt32(try uint(4)))))
            case 0xcb: return .double(Double(bitPattern: try uint(8)))
            case 0xcc: return .int(Int64(try uint(1)))
            case 0xcd: return .int(Int64(try uint(2)))
            case 0xce: return .int(Int64(try uint(4)))
            case 0xcf: return .int(Int64(truncatingIfNeeded: try uint(8)))
            case 0xd0: return .int(Int64(Int8(truncatingIfNeeded: try uint(1))))
            case 0xd1: return .int(Int64(Int16(truncatingIfNeeded: try uint(2))))
            case 0xd2: return .int(Int64(Int32(truncatingIfNeeded: try uint(4))))
            case 0xd3: return .int(Int64(bitPattern: try uint(8)))
            case 0xd8: return .string(String(decoding: try raw(Int(try uint(2))), as: UTF8.self))
            case 0xd9: return .string(String(decoding: try raw(Int(try uint(4))), as: UTF8.self))
            case 0xda: return .binary(Data(try raw(Int(try uint(2)))))
            case 0xdb: return .binary(Data(try raw(Int(try uint(4)))))
            case 0xdc: return try array(Int(try uint(2)))
            case 0xdd: return try array(Int(try uint(4)))
            case 0xde: return try map(Int(try uint(2)))
            case 0xdf: return try map(Int(try uint(4)))
            default: throw DecodeError()
            }
        }

        mutating func array(_ count: Int) throws -> PackValue {
            var items: [PackValue] = []
            items.reserveCapacity(min(count, 1024))
            for _ in 0..<count { items.append(try value()) }
            return .array(items)
        }

        mutating func map(_ count: Int) throws -> PackValue {
            var pairs: [(String, PackValue)] = []
            for _ in 0..<count {
                let key = try value()
                let item = try value()
                switch key {
                case .string(let s): pairs.append((s, item))
                case .int(let i): pairs.append((String(i), item))
                default: continue
                }
            }
            return .map(pairs)
        }
    }
}
