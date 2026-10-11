public enum OCFCodec: String, Equatable, Sendable {
    case null
    case deflate
}

public struct OCFHeader: Equatable, Sendable {
    public var schemaJSON: String
    public var codec: OCFCodec
    public var sync: [UInt8]
    public var metadata: [String: [UInt8]]
    public var bodyOffset: Int
}

public struct OCFWriter {
    public var schemaJSON: String
    public var codec: OCFCodec
    public var sync: [UInt8]
    public var metadata: [String: [UInt8]]
    public var objectsPerBlock: Int
    var pending: [UInt8] = []
    var pendingCount = 0
    var blocks: [UInt8] = []
    var finished = false

    public init(
        schemaJSON: String,
        codec: OCFCodec = .null,
        sync: [UInt8]? = nil,
        metadata: [String: [UInt8]] = [:],
        objectsPerBlock: Int = Int.max
    ) {
        self.schemaJSON = schemaJSON
        self.codec = codec
        if let sync, sync.count == 16 {
            self.sync = sync
        } else {
            self.sync = deterministicSync(schemaJSON)
        }
        self.metadata = metadata
        self.objectsPerBlock = max(1, objectsPerBlock)
    }

    public mutating func appendDatum(_ bytes: [UInt8]) {
        pending.append(contentsOf: bytes)
        pendingCount += 1
        if pendingCount >= objectsPerBlock {
            flushBlock()
        }
    }

    public mutating func append<T: AvroCodable>(_ value: T) {
        appendDatum(encode(value))
    }

    public mutating func appendGeneric(_ value: AvroValue, pool: SchemaPool, root: Int? = nil) throws {
        appendDatum(try encodeGeneric(value, pool: pool, root: root))
    }

    public mutating func finish() -> [UInt8] {
        flushBlock()
        var encoder = BinaryEncoder()
        encoder.writeFixed(ocfMagic)
        writeMetadata(into: &encoder)
        encoder.writeFixed(sync)
        encoder.writeFixed(blocks)
        finished = true
        return encoder.bytes
    }

    mutating func flushBlock() {
        guard pendingCount > 0 else { return }
        let raw = pending
        let compressed: [UInt8]
        switch codec {
        case .null:
            compressed = raw
        case .deflate:
            compressed = deflateRaw(raw)
        }
        var encoder = BinaryEncoder()
        encoder.writeLong(Int64(pendingCount))
        encoder.writeLong(Int64(compressed.count))
        encoder.writeFixed(compressed)
        encoder.writeFixed(sync)
        blocks.append(contentsOf: encoder.bytes)
        pending.removeAll(keepingCapacity: true)
        pendingCount = 0
    }

    func writeMetadata(into encoder: inout BinaryEncoder) {
        var pairs: [(String, [UInt8])] = [
            (avroSchemaKey, Array(schemaJSON.utf8)),
            (avroCodecKey, Array(codec.rawValue.utf8)),
        ]
        for key in metadata.keys.sorted() where key != avroSchemaKey && key != avroCodecKey {
            pairs.append((key, metadata[key] ?? []))
        }
        encoder.writeLong(Int64(pairs.count))
        for (key, value) in pairs {
            encoder.writeString(key)
            encoder.writeBytes(value)
        }
        encoder.writeBlockEnd()
    }
}

public func readOCFHeader(_ bytes: [UInt8]) throws -> OCFHeader {
    var decoder = BinaryDecoder(bytes)
    let magic = try decoder.readFixed(4)
    guard magic == ocfMagic else {
        throw DecodeError(kind: .ocf, offset: 0, message: "magic")
    }
    var meta: [String: [UInt8]] = [:]
    while true {
        let count = try decoder.readBlockCount()
        if count == 0 { break }
        for _ in 0..<count {
            let key = try decoder.readString()
            let value = try decoder.readBytes()
            meta[key] = value
        }
        try decoder.endBlock()
    }
    let sync = try decoder.readFixed(16)
    guard let schemaBytes = meta[avroSchemaKey] else {
        throw DecodeError(kind: .ocf, offset: decoder.offset, message: "missing avro.schema")
    }
    if schemaBytes.count > avroMaxSchemaBytes {
        throw DecodeError(kind: .schema, offset: decoder.offset, message: "schema too large")
    }
    guard let schemaJSON = utf8String(schemaBytes) else {
        throw DecodeError(kind: .ocf, offset: decoder.offset, message: "schema utf-8")
    }
    let codecName: String
    if let codecBytes = meta[avroCodecKey] {
        guard let text = utf8String(codecBytes) else {
            throw DecodeError(kind: .ocf, offset: decoder.offset, message: "codec utf-8")
        }
        codecName = text
    } else {
        codecName = "null"
    }
    guard let codec = OCFCodec(rawValue: codecName) else {
        throw DecodeError(kind: .ocf, offset: decoder.offset, message: "unknown codec \(codecName)")
    }
    return OCFHeader(schemaJSON: schemaJSON, codec: codec, sync: sync, metadata: meta, bodyOffset: decoder.offset)
}

public func readOCFGeneric(_ bytes: [UInt8], readerSchemaJSON: String? = nil) throws -> [AvroValue] {
    let header = try readOCFHeader(bytes)
    let writer = try parseSchemaOrOCF(header.schemaJSON)
    let reader: SchemaPool
    if let readerSchemaJSON {
        reader = try parseSchemaOrOCF(readerSchemaJSON)
    } else {
        reader = writer
    }
    let state = ResolveState()
    guard state.canResolve(writer.root, writer, reader.root, reader) else {
        throw DecodeError(kind: .resolve, offset: header.bodyOffset, message: "ocf schema")
    }
    var decoder = BinaryDecoder(bytes)
    decoder.offset = header.bodyOffset
    var values: [AvroValue] = []
    while decoder.offset < bytes.count {
        let count: Int
        let size: Int
        do {
            let rawCount = try decoder.readLong()
            if rawCount < 0 || rawCount > Int64(avroMaxBlockItems) {
                throw DecodeError(kind: .ocf, offset: decoder.offset, message: "object count")
            }
            count = Int(rawCount)
            let rawSize = try decoder.readLong()
            if rawSize < 0 || rawSize > Int64(decoder.remaining) {
                throw DecodeError(kind: .ocf, offset: decoder.offset, message: "block size")
            }
            size = Int(rawSize)
        } catch let error as DecodeError {
            if error.kind == .eof { throw DecodeError(kind: .ocf, offset: error.offset, message: "truncated block") }
            throw error
        }
        let compressed = try decoder.readFixed(size)
        let raw: [UInt8]
        switch header.codec {
        case .null:
            raw = compressed
        case .deflate:
            do {
                raw = try inflateRaw(compressed)
            } catch let error as DecodeError {
                throw DecodeError(kind: .deflate, offset: decoder.offset, field: error.field, message: error.message)
            }
        }
        var block = BinaryDecoder(raw)
        for _ in 0..<count {
            values.append(try state.resolve(writer.root, writer, reader.root, reader, &block))
        }
        if !block.isAtEnd {
            throw DecodeError(kind: .ocf, offset: decoder.offset, message: "block trailing bytes")
        }
        let marker = try decoder.readFixed(16)
        if marker != header.sync {
            throw DecodeError(kind: .ocf, offset: decoder.offset - 16, message: "sync")
        }
    }
    return values
}

public func readOCF<T: AvroCodable>(_ type: T.Type, from bytes: [UInt8]) throws -> [T] {
    let values = try readOCFGeneric(bytes, readerSchemaJSON: T.schemaJSON)
    return try values.map { try T.fromResolved($0) }
}

func parseSchemaOrOCF(_ text: String) throws -> SchemaPool {
    do {
        return try parseAvsc(text)
    } catch {
        throw DecodeError(kind: .schema, offset: 0, message: String(describing: error))
    }
}

func deterministicSync(_ schemaJSON: String) -> [UInt8] {
    let first = crc64Avro(schemaJSON)
    let second = crc64Avro(bytes: crc64AvroLittleEndianBytes(first) + [0x41, 0x56, 0x52, 0x4f])
    return crc64AvroLittleEndianBytes(first) + crc64AvroLittleEndianBytes(second)
}
