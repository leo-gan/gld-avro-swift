public enum AvroLogical {
    public static func days(year: Int, month: Int, day: Int) -> Int32 {
        var year = year
        let month = month
        year -= month <= 2 ? 1 : 0
        let era = year >= 0 ? year : year - 399
        let yearOfEra = year - era / 400 * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int32(era / 400 * 146097 + dayOfEra - 719468)
    }

    public static func ymd(days: Int32) -> (year: Int, month: Int, day: Int) {
        let z = Int(days) + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let dayOfEra = z - era * 146097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return (month <= 2 ? year + 1 : year, month, day)
    }

    public static func validateUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        let dashes = [8, 13, 18, 23]
        for index in 0..<36 {
            if dashes.contains(index) {
                if bytes[index] != 0x2d { return false }
            } else if !isHex(bytes[index]) {
                return false
            }
        }
        return true
    }

    public static func decimalUnscaled(_ bytes: [UInt8]) throws -> Int64 {
        guard !bytes.isEmpty, bytes.count <= 8 else {
            throw DecodeError(kind: .range, offset: 0, message: "decimal width")
        }
        var value: Int64 = (bytes[0] & 0x80) == 0 ? 0 : -1
        for byte in bytes {
            value = (value << 8) | Int64(byte)
        }
        return value
    }

    public static func decimalBytes(_ value: Int64) -> [UInt8] {
        var raw = value
        var bytes: [UInt8] = []
        for _ in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: raw & 0xff))
            raw >>= 8
        }
        while bytes.count > 1 {
            let high = bytes.last!
            let next = bytes[bytes.count - 2]
            if high == 0 && next & 0x80 == 0 { bytes.removeLast(); continue }
            if high == 0xff && next & 0x80 != 0 { bytes.removeLast(); continue }
            break
        }
        return bytes.reversed()
    }
}

public struct AvroDuration: Equatable, Sendable {
    public var months: UInt32
    public var days: UInt32
    public var milliseconds: UInt32

    public init(months: UInt32, days: UInt32, milliseconds: UInt32) {
        self.months = months
        self.days = days
        self.milliseconds = milliseconds
    }

    public init(fixedBytes bytes: [UInt8]) throws {
        guard bytes.count == 12 else {
            throw DecodeError(kind: .range, offset: 0, message: "duration")
        }
        months = load(bytes, 0)
        days = load(bytes, 4)
        milliseconds = load(bytes, 8)
    }

    public func fixedBytes() -> [UInt8] {
        store(months) + store(days) + store(milliseconds)
    }
}

private func load(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func store(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
    ]
}

private func isHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
}
