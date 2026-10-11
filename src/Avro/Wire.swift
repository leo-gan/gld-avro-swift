public let avroMaxBlockItems = 8_000_000

@inline(__always)
public func zigzagEncode(_ value: Int64) -> UInt64 {
    let bits = UInt64(bitPattern: value)
    return (bits << 1) ^ UInt64(bitPattern: value >> 63)
}

@inline(__always)
public func zigzagDecode(_ value: UInt64) -> Int64 {
    Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
}

public enum AvroBinary {
    public static func zigzagLength(of value: Int64) -> Int {
        var unsigned = zigzagEncode(value)
        var length = 1
        while unsigned > 0x7f {
            unsigned >>= 7
            length += 1
        }
        return length
    }

    public static func intLength(_ value: Int32) -> Int { zigzagLength(of: Int64(value)) }
    public static func longLength(_ value: Int64) -> Int { zigzagLength(of: value) }
    public static func bytesLength(count: Int) -> Int { zigzagLength(of: Int64(count)) + count }
    public static func stringLength(_ value: String) -> Int {
        bytesLength(count: value.utf8.count)
    }
}

public struct BinaryEncoder: Sendable {
    public private(set) var bytes: [UInt8]

    public init(reserving capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func reserve(_ additional: Int) {
        bytes.reserveCapacity(bytes.count + additional)
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
    }

    public mutating func writeNull() {}

    public mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    @inline(__always)
    public mutating func writeVarint(_ value: UInt64) {
        if value < 0x80 {
            bytes.append(UInt8(value))
            return
        }
        var rest = value
        while rest > 0x7f {
            bytes.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    @inline(__always)
    public mutating func writeLong(_ value: Int64) {
        writeVarint(zigzagEncode(value))
    }

    @inline(__always)
    public mutating func writeInt(_ value: Int32) {
        writeLong(Int64(value))
    }

    @inline(__always)
    public mutating func writeFloat(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }

    @inline(__always)
    public mutating func writeDouble(_ value: Double) {
        let bits = value.bitPattern
        appendLittleEndian(UInt32(truncatingIfNeeded: bits))
        appendLittleEndian(UInt32(truncatingIfNeeded: bits >> 32))
    }

    @inline(__always)
    mutating func appendLittleEndian(_ bits: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: bits))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
    }

    public mutating func writeFixed(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    public mutating func writeFixed(_ value: ArraySlice<UInt8>) {
        bytes.append(contentsOf: value)
    }

    public mutating func writeBytes(_ value: [UInt8]) {
        writeLong(Int64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeString(_ value: String) {
        let utf8 = value.utf8
        let count = utf8.count
        writeLong(Int64(count))
        if count == 0 { return }
        var copied = false
        utf8.withContiguousStorageIfAvailable { raw in
            bytes.append(contentsOf: raw)
            copied = true
        }
        if !copied {
            bytes.append(contentsOf: utf8)
        }
    }

    public mutating func writeBlockEnd() {
        writeLong(0)
    }
}

public struct BinaryDecoder: Sendable {
    public let bytes: [UInt8]
    public var offset: Int
    var blockEnd: Int?

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.blockEnd = nil
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw DecodeError(kind: .eof, offset: offset, message: "byte")
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func readExact(_ count: Int) throws -> ArraySlice<UInt8> {
        if count < 0 {
            throw DecodeError(kind: .range, offset: offset, message: "negative length")
        }
        guard count <= remaining else {
            throw DecodeError(kind: .eof, offset: offset, message: "need \(count) bytes")
        }
        let start = offset
        offset += count
        return bytes[start..<offset]
    }

    @inline(__always)
    public mutating func readVarint() throws -> UInt64 {
        let start = offset
        guard offset < bytes.count else {
            throw DecodeError(kind: .eof, offset: start, message: "varint")
        }
        let first = bytes[offset]
        if first < 0x80 {
            offset += 1
            return UInt64(first)
        }
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else {
                throw DecodeError(kind: .eof, offset: start, message: "varint")
            }
            let byte = bytes[offset]
            offset += 1
            if index == 9 && byte > 1 {
                throw DecodeError(kind: .badVarint, offset: start, message: "overlong")
            }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        throw DecodeError(kind: .badVarint, offset: start, message: "too long")
    }

    @inline(__always)
    public mutating func readLong() throws -> Int64 {
        zigzagDecode(try readVarint())
    }

    @inline(__always)
    public mutating func readInt() throws -> Int32 {
        let value = try readLong()
        if value < Int64(Int32.min) || value > Int64(Int32.max) {
            throw DecodeError(kind: .range, offset: offset, message: "int")
        }
        return Int32(value)
    }

    public mutating func readBool() throws -> Bool {
        let byte = try readByte()
        switch byte {
        case 0: return false
        case 1: return true
        default:
            throw DecodeError(kind: .badBool, offset: offset - 1, message: "byte \(byte)")
        }
    }

    @inline(__always)
    public mutating func readFloat() throws -> Float {
        guard remaining >= 4 else {
            throw DecodeError(kind: .eof, offset: offset, message: "float")
        }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        offset += 4
        return Float(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    }

    @inline(__always)
    public mutating func readDouble() throws -> Double {
        guard remaining >= 8 else {
            throw DecodeError(kind: .eof, offset: offset, message: "double")
        }
        var bits: UInt64 = 0
        for shift in 0..<8 {
            bits |= UInt64(bytes[offset + shift]) << (UInt64(shift) * 8)
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    public mutating func readFixed(_ count: Int) throws -> [UInt8] {
        Array(try readExact(count))
    }

    public mutating func readBytes() throws -> [UInt8] {
        let count = try readCount()
        return Array(try readExact(count))
    }

    public mutating func readString() throws -> String {
        let count = try readCount()
        let raw = try readExact(count)
        guard let text = utf8String(raw) else {
            throw DecodeError(kind: .badUTF8, offset: offset - count, message: "string")
        }
        return text
    }

    public mutating func readCount() throws -> Int {
        let value = try readLong()
        if value < 0 || value > Int64(Int.max) {
            throw DecodeError(kind: .range, offset: offset, message: "count")
        }
        return Int(value)
    }

    /// Item count for the next array or map block. `0` ends the sequence.
    /// A negative wire count consumes the following size long. Call `endBlock()`
    /// after the items when a size hint was present.
    public mutating func readBlockCount() throws -> Int {
        let start = offset
        let raw = try readLong()
        if raw == 0 {
            return 0
        }
        if raw < 0 {
            if raw == Int64.min {
                throw DecodeError(kind: .range, offset: start, message: "block count")
            }
            let count = -raw
            if count > Int64(avroMaxBlockItems) {
                throw DecodeError(kind: .range, offset: start, message: "block count")
            }
            let size = try readLong()
            if size < 0 || size > Int64(Int.max) {
                throw DecodeError(kind: .badBlock, offset: offset, message: "block size")
            }
            let end = offset + Int(size)
            if end > bytes.count {
                throw DecodeError(kind: .eof, offset: offset, message: "block")
            }
            blockEnd = end
            return Int(count)
        }
        if raw > Int64(avroMaxBlockItems) {
            throw DecodeError(kind: .range, offset: start, message: "block count")
        }
        return Int(raw)
    }

    public mutating func endBlock() throws {
        guard let end = blockEnd else { return }
        if offset != end {
            throw DecodeError(kind: .badBlock, offset: offset, message: "block size mismatch")
        }
        blockEnd = nil
    }

    public mutating func skip(_ count: Int) throws {
        _ = try readExact(count)
    }
}

func utf8String(_ bytes: ArraySlice<UInt8>) -> String? {
    var index = bytes.startIndex
    let end = bytes.endIndex
    while index < end {
        if bytes[index] >= 0x80 { break }
        index = bytes.index(after: index)
    }
    if index == end {
        let count = bytes.count
        if count == 0 { return "" }
        return String(unsafeUninitializedCapacity: count) { buffer in
            var cursor = 0
            for byte in bytes {
                buffer[cursor] = byte
                cursor += 1
            }
            return cursor
        }
    }
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(bytes.count)
    index = bytes.startIndex
    while index < end {
        let b0 = bytes[index]
        index = bytes.index(after: index)
        if b0 < 0x80 {
            scalars.append(UnicodeScalar(b0))
            continue
        }
        let width: Int
        let minScalar: UInt32
        let firstMask: UInt8
        if b0 & 0xe0 == 0xc0 {
            width = 2
            minScalar = 0x80
            firstMask = 0x1f
            if b0 < 0xc2 { return nil }
        } else if b0 & 0xf0 == 0xe0 {
            width = 3
            minScalar = 0x800
            firstMask = 0x0f
        } else if b0 & 0xf8 == 0xf0 {
            width = 4
            minScalar = 0x10000
            firstMask = 0x07
            if b0 > 0xf4 { return nil }
        } else {
            return nil
        }
        var scalar = UInt32(b0 & firstMask)
        for _ in 1..<width {
            if index == end { return nil }
            let next = bytes[index]
            index = bytes.index(after: index)
            if next & 0xc0 != 0x80 { return nil }
            scalar = (scalar << 6) | UInt32(next & 0x3f)
        }
        if scalar < minScalar || scalar > 0x10ffff { return nil }
        if scalar >= 0xd800 && scalar <= 0xdfff { return nil }
        if b0 == 0xe0 && scalar < 0x800 { return nil }
        if b0 == 0xed && scalar >= 0xd800 { return nil }
        if b0 == 0xf0 && scalar < 0x10000 { return nil }
        if b0 == 0xf4 && scalar > 0x10ffff { return nil }
        guard let unicode = UnicodeScalar(scalar) else { return nil }
        scalars.append(unicode)
    }
    return String(scalars)
}

func utf8String(_ bytes: [UInt8]) -> String? {
    utf8String(bytes[...])
}
