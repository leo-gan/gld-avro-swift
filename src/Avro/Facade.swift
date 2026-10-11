public protocol AvroCodable {
    func encodedByteLength() -> Int
    func encode(into encoder: inout BinaryEncoder)
    static func decode(from decoder: inout BinaryDecoder) throws -> Self
    static var schemaJSON: String { get }
    static func fromResolved(_ value: AvroValue) throws -> Self
}

public func encode<T: AvroCodable>(_ value: T) -> [UInt8] {
    var encoder = BinaryEncoder(reserving: value.encodedByteLength())
    value.encode(into: &encoder)
    return encoder.bytes
}

public func decode<T: AvroCodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
    var decoder = BinaryDecoder(bytes)
    return try T.decode(from: &decoder)
}

public func decodeResolving<T: AvroCodable>(_ type: T.Type, from bytes: [UInt8], writerSchemaJSON: String) throws -> T {
    let writer = try parseAvsc(writerSchemaJSON)
    let reader = try parseAvsc(T.schemaJSON)
    let value = try decodeResolving(bytes, writer: writer, reader: reader)
    return try T.fromResolved(value)
}

public func encodeJSON<T: AvroCodable>(_ value: T) throws -> String {
    let pool = try parseAvsc(T.schemaJSON)
    let generic = try decodeGeneric(encode(value), pool: pool)
    return try encodeJSON(generic, pool: pool)
}

public func decodeJSON<T: AvroCodable>(_ type: T.Type, _ text: String) throws -> T {
    let pool = try parseAvsc(T.schemaJSON)
    let value = try decodeJSON(text, pool: pool)
    return try T.fromResolved(value)
}

public final class Box<T> {
    public var value: T
    public init(_ value: T) { self.value = value }
}

public struct AvroNull: Equatable, Sendable {
    public init() {}
}

public let singleObjectMarker: [UInt8] = [0xc3, 0x01]
public let ocfMagic: [UInt8] = [0x4f, 0x62, 0x6a, 0x01]
public let avroSchemaKey = "avro.schema"
public let avroCodecKey = "avro.codec"
public let avroMaxSchemaBytes = 4_194_304
