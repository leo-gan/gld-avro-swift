#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.number(let left), .number(let right)):
            return left == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.array(let left), .array(let right)):
            guard left.count == right.count else { return false }
            for index in 0..<left.count where left[index] != right[index] { return false }
            return true
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            for index in 0..<left.count where left[index].0 != right[index].0 || left[index].1 != right[index].1 {
                return false
            }
            return true
        default:
            return false
        }
    }

    public var objectFields: [String: JSONValue] {
        guard case .object(let pairs) = self else { return [:] }
        var map: [String: JSONValue] = [:]
        map.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            map[key] = value
        }
        return map
    }

    public func stringValue() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public func parseJSON(_ text: String) throws -> JSONValue {
    var parser = JSONParser(text)
    return try parser.parse()
}

public func emitJSON(_ value: JSONValue) -> String {
    var out = ""
    out.reserveCapacity(64)
    emitJSON(value, into: &out)
    return out
}

func emitJSON(_ value: JSONValue, into out: inout String) {
    switch value {
    case .null:
        out += "null"
    case .bool(let flag):
        out += flag ? "true" : "false"
    case .number(let raw):
        out += raw
    case .string(let text):
        appendJSONString(text, into: &out)
    case .array(let items):
        out += "["
        for (index, item) in items.enumerated() {
            if index > 0 { out += "," }
            emitJSON(item, into: &out)
        }
        out += "]"
    case .object(let pairs):
        out += "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { out += "," }
            appendJSONString(pair.0, into: &out)
            out += ":"
            emitJSON(pair.1, into: &out)
        }
        out += "}"
    }
}

func appendJSONString(_ text: String, into out: inout String) {
    out += "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x22:
            out += "\\\""
        case 0x5c:
            out += "\\\\"
        case 0x08:
            out += "\\b"
        case 0x0c:
            out += "\\f"
        case 0x0a:
            out += "\\n"
        case 0x0d:
            out += "\\r"
        case 0x09:
            out += "\\t"
        case let value where value < 0x20:
            out += String(format: "\\u%04x", value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
}

struct JSONParser {
    let bytes: [UInt8]
    var index: Int

    init(_ text: String) {
        bytes = Array(text.utf8)
        index = 0
    }

    mutating func parse() throws -> JSONValue {
        if bytes.count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
            index = 3
        }
        try skip()
        let value = try parseValue()
        try skip()
        if index != bytes.count {
            throw JSONError(message: "trailing data", offset: index)
        }
        return value
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else {
            throw JSONError(message: "unexpected end", offset: index)
        }
        switch bytes[index] {
        case 0x6e: return try literal("null", .null)
        case 0x74: return try literal("true", .bool(true))
        case 0x66: return try literal("false", .bool(false))
        case 0x22: return .string(try parseString())
        case 0x5b: return try parseArray()
        case 0x7b: return try parseObject()
        case 0x2d, 0x30...0x39: return .number(try parseNumber())
        default:
            throw JSONError(message: "invalid value", offset: index)
        }
    }

    mutating func literal(_ text: String, _ value: JSONValue) throws -> JSONValue {
        let raw = Array(text.utf8)
        guard index + raw.count <= bytes.count else {
            throw JSONError(message: "truncated literal", offset: index)
        }
        for (offset, byte) in raw.enumerated() where bytes[index + offset] != byte {
            throw JSONError(message: "invalid literal", offset: index)
        }
        index += raw.count
        return value
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1
        try skip()
        var items: [JSONValue] = []
        if index < bytes.count && bytes[index] == 0x5d {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            try skip()
            guard index < bytes.count else {
                throw JSONError(message: "unterminated array", offset: index)
            }
            if bytes[index] == 0x2c {
                index += 1
                try skip()
                continue
            }
            if bytes[index] == 0x5d {
                index += 1
                return .array(items)
            }
            throw JSONError(message: "expected comma or ]", offset: index)
        }
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1
        try skip()
        var pairs: [(String, JSONValue)] = []
        if index < bytes.count && bytes[index] == 0x7d {
            index += 1
            return .object(pairs)
        }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw JSONError(message: "expected object key", offset: index)
            }
            let key = try parseString()
            try skip()
            guard index < bytes.count, bytes[index] == 0x3a else {
                throw JSONError(message: "expected colon", offset: index)
            }
            index += 1
            try skip()
            let value = try parseValue()
            pairs.append((key, value))
            try skip()
            guard index < bytes.count else {
                throw JSONError(message: "unterminated object", offset: index)
            }
            if bytes[index] == 0x2c {
                index += 1
                try skip()
                continue
            }
            if bytes[index] == 0x7d {
                index += 1
                return .object(pairs)
            }
            throw JSONError(message: "expected comma or }", offset: index)
        }
    }

    mutating func parseNumber() throws -> String {
        let start = index
        if bytes[index] == 0x2d {
            index += 1
        }
        guard index < bytes.count, isDigit(bytes[index]) else {
            throw JSONError(message: "invalid number", offset: start)
        }
        if bytes[index] == 0x30 {
            index += 1
        } else {
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 0x2e {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw JSONError(message: "invalid fraction", offset: start)
            }
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2b || bytes[index] == 0x2d) {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw JSONError(message: "invalid exponent", offset: start)
            }
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func parseString() throws -> String {
        let start = index
        index += 1
        var scalars = String.UnicodeScalarView()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return String(scalars)
            }
            if byte == 0x5c {
                index += 1
                guard index < bytes.count else {
                    throw JSONError(message: "truncated escape", offset: start)
                }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case 0x22: scalars.append(UnicodeScalar(0x22))
                case 0x5c: scalars.append(UnicodeScalar(0x5c))
                case 0x2f: scalars.append(UnicodeScalar(0x2f))
                case 0x62: scalars.append(UnicodeScalar(0x08))
                case 0x66: scalars.append(UnicodeScalar(0x0c))
                case 0x6e: scalars.append(UnicodeScalar(0x0a))
                case 0x72: scalars.append(UnicodeScalar(0x0d))
                case 0x74: scalars.append(UnicodeScalar(0x09))
                case 0x75:
                    let unit = try hex4()
                    if unit >= 0xd800 && unit <= 0xdbff {
                        guard index + 1 < bytes.count, bytes[index] == 0x5c, bytes[index + 1] == 0x75 else {
                            throw JSONError(message: "lone surrogate", offset: index)
                        }
                        index += 2
                        let low = try hex4()
                        guard low >= 0xdc00 && low <= 0xdfff else {
                            throw JSONError(message: "bad surrogate pair", offset: index)
                        }
                        let scalar = 0x10000 + ((UInt32(unit) - 0xd800) << 10) + (UInt32(low) - 0xdc00)
                        scalars.append(UnicodeScalar(scalar)!)
                    } else if unit >= 0xdc00 && unit <= 0xdfff {
                        throw JSONError(message: "lone surrogate", offset: index)
                    } else {
                        scalars.append(UnicodeScalar(unit)!)
                    }
                default:
                    throw JSONError(message: "bad escape", offset: index - 1)
                }
                continue
            }
            if byte < 0x20 {
                throw JSONError(message: "raw control character", offset: index)
            }
            let sliceStart = index
            while index < bytes.count {
                let current = bytes[index]
                if current == 0x22 || current == 0x5c || current < 0x20 { break }
                index += 1
            }
            guard let chunk = utf8String(bytes[sliceStart..<index]) else {
                throw JSONError(message: "bad utf-8 in string", offset: sliceStart)
            }
            for scalar in chunk.unicodeScalars {
                scalars.append(scalar)
            }
        }
        throw JSONError(message: "unterminated string", offset: start)
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw JSONError(message: "short unicode escape", offset: index)
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x61...0x66: digit = UInt32(byte - 0x61) + 10
            case 0x41...0x46: digit = UInt32(byte - 0x41) + 10
            default:
                throw JSONError(message: "bad hex", offset: index - 1)
            }
            value = (value << 4) | digit
        }
        return value
    }

    mutating func skip() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            default:
                return
            }
        }
    }
}

func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

func jsonInteger(_ raw: String) -> Int64? {
    if raw.contains(".") || raw.contains("e") || raw.contains("E") { return nil }
    if raw.isEmpty || raw == "-" { return nil }
    var negative = false
    var digits = raw
    if raw.first == "-" {
        negative = true
        digits = String(raw.dropFirst())
    }
    if digits.count > 1 && digits.first == "0" { return nil }
    var value: UInt64 = 0
    for byte in digits.utf8 {
        if !isDigit(byte) { return nil }
        let digit = UInt64(byte - 0x30)
        if value > (UInt64.max - digit) / 10 { return nil }
        value = value * 10 + digit
    }
    if negative {
        if value > UInt64(Int64.max) + 1 { return nil }
        if value == UInt64(Int64.max) + 1 { return Int64.min }
        return -Int64(value)
    }
    if value > UInt64(Int64.max) { return nil }
    return Int64(value)
}

func jsonDouble(_ raw: String) -> Double? {
    if raw.isEmpty { return nil }
    return raw.withCString { pointer in
        errno = 0
        var end: UnsafeMutablePointer<CChar>? = nil
        let value = strtod(pointer, &end)
        guard let end, end.pointee == 0, errno != ERANGE else { return nil }
        if value.isNaN || value.isInfinite { return nil }
        return value
    }
}

func jsonNumberString(_ value: Double) -> String? {
    if value.isNaN || value.isInfinite { return nil }
    return String(value)
}

func jsonNumberString(_ value: Float) -> String? {
    if value.isNaN || value.isInfinite { return nil }
    return String(Double(value))
}
