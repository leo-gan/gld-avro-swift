public func schemaFingerprint(_ schemaJSON: String) throws -> UInt64 {
    let pool = try parseAvsc(schemaJSON)
    return crc64Avro(canonicalForm(pool))
}

public func encodeSingleObject<T: AvroCodable>(_ value: T) throws -> [UInt8] {
    let fingerprint = try schemaFingerprint(T.schemaJSON)
    var bytes = singleObjectMarker
    bytes.append(contentsOf: crc64AvroLittleEndianBytes(fingerprint))
    bytes.append(contentsOf: encode(value))
    return bytes
}

public func decodeSingleObject<T: AvroCodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
    let payload = try singleObjectPayload(bytes, expected: try schemaFingerprint(T.schemaJSON))
    return try decode(T.self, from: payload)
}

public func decodeSingleObject<T: AvroCodable>(
    _ type: T.Type,
    from bytes: [UInt8],
    writerSchemaJSON: String
) throws -> T {
    let payload = try singleObjectPayload(bytes, expected: try schemaFingerprint(writerSchemaJSON))
    return try decodeResolving(T.self, from: payload, writerSchemaJSON: writerSchemaJSON)
}

public func singleObjectFingerprint(_ bytes: [UInt8]) throws -> UInt64 {
    guard bytes.count >= 10, bytes[0] == 0xc3, bytes[1] == 0x01 else {
        throw DecodeError(kind: .soe, offset: 0, message: "marker")
    }
    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(bytes[2 + index]) << (UInt64(index) * 8)
    }
    return value
}

func singleObjectPayload(_ bytes: [UInt8], expected: UInt64) throws -> [UInt8] {
    let found = try singleObjectFingerprint(bytes)
    if found != expected {
        throw DecodeError(kind: .soe, offset: 2, message: "fingerprint")
    }
    return Array(bytes.dropFirst(10))
}
