public let avroLibraryVersion = "0.2.0"

public struct DecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Int, Equatable, Sendable {
        case eof = 1
        case badVarint = 2
        case range = 3
        case badBool = 4
        case badUTF8 = 5
        case badEnum = 6
        case badUnion = 7
        case badBlock = 8
        case schema = 9
        case resolve = 10
        case ocf = 11
        case deflate = 12
        case json = 13
        case soe = 14
        case badJSONNumber = 15
    }

    public var kind: Kind
    public var offset: Int
    public var field: Int
    public var message: String

    public init(kind: Kind, offset: Int, field: Int = 0, message: String = "") {
        self.kind = kind
        self.offset = offset
        self.field = field
        self.message = message
    }

    public var description: String {
        var text = "DecodeError(kind: \(kind.rawValue), offset: \(offset), field: \(field)"
        if !message.isEmpty { text += ", \(message)" }
        text += ")"
        return text
    }
}

public struct SchemaError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var path: String

    public init(message: String, path: String = "") {
        self.message = message
        self.path = path
    }

    public var description: String {
        path.isEmpty ? "SchemaError(\(message))" : "SchemaError(\(path): \(message))"
    }
}

public struct JSONError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var offset: Int

    public init(message: String, offset: Int) {
        self.message = message
        self.offset = offset
    }

    public var description: String {
        "JSONError(offset: \(offset), \(message))"
    }
}

public struct CodegenError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

func wrapField(_ error: Error, field: Int) -> Error {
    guard let decode = error as? DecodeError, decode.field == 0 else { return error }
    return DecodeError(kind: decode.kind, offset: decode.offset, field: field, message: decode.message)
}
