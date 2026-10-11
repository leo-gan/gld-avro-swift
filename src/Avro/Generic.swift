#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private final class EncoderScratch {
    var encoder = BinaryEncoder(reserving: 128)
}

private let encoderScratchKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key) { pointer in
        guard let pointer else { return }
        Unmanaged<EncoderScratch>.fromOpaque(pointer).release()
    }
    return key
}()

private func encoderScratch() -> EncoderScratch {
    if let raw = pthread_getspecific(encoderScratchKey) {
        return Unmanaged<EncoderScratch>.fromOpaque(raw).takeUnretainedValue()
    }
    let scratch = EncoderScratch()
    pthread_setspecific(encoderScratchKey, Unmanaged.passRetained(scratch).toOpaque())
    return scratch
}

public enum AvroValue: Equatable, Sendable {
    case null
    case boolean(Bool)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case bytes([UInt8])
    case string(String)
    case enumeration(String)
    case fixed([UInt8])
    indirect case array([AvroValue])
    indirect case map([(String, AvroValue)])
    indirect case record([AvroValue])
    indirect case union(index: Int, value: AvroValue)

    public static func == (lhs: AvroValue, rhs: AvroValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.boolean(let a), .boolean(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.long(let a), .long(let b)):
            return a == b
        case (.float(let a), .float(let b)):
            return a.bitPattern == b.bitPattern
        case (.double(let a), .double(let b)):
            return a.bitPattern == b.bitPattern
        case (.bytes(let a), .bytes(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.enumeration(let a), .enumeration(let b)):
            return a == b
        case (.fixed(let a), .fixed(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for index in 0..<a.count where a[index] != b[index] { return false }
            return true
        case (.map(let a), .map(let b)):
            guard a.count == b.count else { return false }
            for index in 0..<a.count where a[index].0 != b[index].0 || a[index].1 != b[index].1 { return false }
            return true
        case (.record(let a), .record(let b)):
            guard a.count == b.count else { return false }
            for index in 0..<a.count where a[index] != b[index] { return false }
            return true
        case (.union(let ia, let a), .union(let ib, let b)):
            return ia == ib && a == b
        default:
            return false
        }
    }
}

public enum AvroResolved {
    public static func bool(_ value: AvroValue) throws -> Bool {
        guard case .boolean(let inner) = value else { throw mismatch("bool") }
        return inner
    }

    public static func int32(_ value: AvroValue) throws -> Int32 {
        guard case .int(let inner) = value else { throw mismatch("int") }
        return inner
    }

    public static func int64(_ value: AvroValue) throws -> Int64 {
        guard case .long(let inner) = value else { throw mismatch("long") }
        return inner
    }

    public static func float32(_ value: AvroValue) throws -> Float {
        guard case .float(let inner) = value else { throw mismatch("float") }
        return inner
    }

    public static func float64(_ value: AvroValue) throws -> Double {
        guard case .double(let inner) = value else { throw mismatch("double") }
        return inner
    }

    public static func bytes(_ value: AvroValue) throws -> [UInt8] {
        guard case .bytes(let inner) = value else { throw mismatch("bytes") }
        return inner
    }

    public static func string(_ value: AvroValue) throws -> String {
        guard case .string(let inner) = value else { throw mismatch("string") }
        return inner
    }

    public static func symbol(_ value: AvroValue) throws -> String {
        switch value {
        case .enumeration(let inner), .string(let inner):
            return inner
        default:
            throw mismatch("enum")
        }
    }

    public static func fixed(_ value: AvroValue, size: Int) throws -> [UInt8] {
        guard case .fixed(let inner) = value, inner.count == size else { throw mismatch("fixed") }
        return inner
    }

    public static func record(_ value: AvroValue, count: Int) throws -> [AvroValue] {
        guard case .record(let fields) = value, fields.count == count else { throw mismatch("record") }
        return fields
    }

    public static func array(_ value: AvroValue) throws -> [AvroValue] {
        guard case .array(let items) = value else { throw mismatch("array") }
        return items
    }

    public static func map(_ value: AvroValue) throws -> [(String, AvroValue)] {
        guard case .map(let pairs) = value else { throw mismatch("map") }
        return pairs
    }

    public static func union(_ value: AvroValue) throws -> (Int, AvroValue) {
        guard case .union(let index, let inner) = value else { throw mismatch("union") }
        return (index, inner)
    }

    public static func null(_ value: AvroValue) throws {
        guard case .null = value else { throw mismatch("null") }
    }
}

func mismatch(_ name: String) -> DecodeError {
    DecodeError(kind: .resolve, offset: 0, message: name)
}

public func encodeGeneric(_ value: AvroValue, pool: SchemaPool, root: Int? = nil) throws -> [UInt8] {
    let scratch = encoderScratch()
    // Shares storage with this thread's scratch. The next encode clears it
    // only after copy-on-write leaves any buffer the caller still holds.
    scratch.encoder.reset()
    try encodeGeneric(value, id: root ?? pool.root, pool: pool, into: &scratch.encoder)
    return scratch.encoder.bytes
}

public func decodeGeneric(_ bytes: [UInt8], pool: SchemaPool, root: Int? = nil) throws -> AvroValue {
    var decoder = BinaryDecoder(bytes)
    return try decodeGeneric(id: root ?? pool.root, pool: pool, from: &decoder)
}

func encodeGeneric(_ value: AvroValue, id: Int, pool: SchemaPool, into encoder: inout BinaryEncoder) throws {
    let node = pool.nodes[id]
    switch node.kind {
    case .null:
        guard case .null = value else { throw typeMismatch("null") }
    case .boolean:
        guard case .boolean(let inner) = value else { throw typeMismatch("boolean") }
        encoder.writeBool(inner)
    case .int:
        guard case .int(let inner) = value else { throw typeMismatch("int") }
        encoder.writeInt(inner)
    case .long:
        guard case .long(let inner) = value else { throw typeMismatch("long") }
        encoder.writeLong(inner)
    case .float:
        guard case .float(let inner) = value else { throw typeMismatch("float") }
        encoder.writeFloat(inner)
    case .double:
        guard case .double(let inner) = value else { throw typeMismatch("double") }
        encoder.writeDouble(inner)
    case .bytes:
        guard case .bytes(let inner) = value else { throw typeMismatch("bytes") }
        encoder.writeBytes(inner)
    case .string:
        guard case .string(let inner) = value else { throw typeMismatch("string") }
        encoder.writeString(inner)
    case .enumeration:
        guard case .enumeration(let symbol) = value, let index = node.symbols.firstIndex(of: symbol) else {
            throw DecodeError(kind: .badEnum, offset: encoder.bytes.count, message: "symbol")
        }
        encoder.writeInt(Int32(index))
    case .fixed:
        guard case .fixed(let inner) = value, inner.count == node.size else { throw typeMismatch("fixed") }
        encoder.writeFixed(inner)
    case .array:
        guard case .array(let items) = value else { throw typeMismatch("array") }
        let itemKind = pool.nodes[node.itemId].kind
        if itemKind == .int {
            if items.isEmpty {
                encoder.writeLong(0)
            } else {
                encoder.writeLong(Int64(items.count))
                for item in items {
                    guard case .int(let inner) = item else { throw typeMismatch("int") }
                    encoder.writeInt(inner)
                }
                encoder.writeBlockEnd()
            }
            return
        }
        if items.isEmpty {
            encoder.writeLong(0)
        } else {
            encoder.writeLong(Int64(items.count))
            for item in items {
                try encodeGeneric(item, id: node.itemId, pool: pool, into: &encoder)
            }
            encoder.writeBlockEnd()
        }
    case .map:
        guard case .map(let pairs) = value else { throw typeMismatch("map") }
        if pool.nodes[node.valueId].kind == .string {
            if pairs.isEmpty {
                encoder.writeLong(0)
            } else {
                encoder.writeLong(Int64(pairs.count))
                for (key, item) in pairs {
                    guard case .string(let inner) = item else { throw typeMismatch("string") }
                    encoder.writeString(key)
                    encoder.writeString(inner)
                }
                encoder.writeBlockEnd()
            }
            return
        }
        if pairs.isEmpty {
            encoder.writeLong(0)
        } else {
            encoder.writeLong(Int64(pairs.count))
            for (key, item) in pairs {
                encoder.writeString(key)
                try encodeGeneric(item, id: node.valueId, pool: pool, into: &encoder)
            }
            encoder.writeBlockEnd()
        }
    case .union:
        if node.branchIds.count == 2,
           pool.nodes[node.branchIds[0]].kind == .null,
           pool.nodes[node.branchIds[1]].kind == .string {
            guard case .union(let index, let inner) = value else { throw typeMismatch("union") }
            if index == 0 {
                encoder.writeLong(0)
                return
            }
            if index == 1 {
                guard case .string(let text) = inner else { throw typeMismatch("string") }
                encoder.writeLong(1)
                encoder.writeString(text)
                return
            }
            throw DecodeError(kind: .badUnion, offset: encoder.bytes.count, message: "branch")
        }
        guard case .union(let index, let inner) = value else { throw typeMismatch("union") }
        guard index >= 0 && index < node.branchIds.count else {
            throw DecodeError(kind: .badUnion, offset: encoder.bytes.count, message: "branch")
        }
        encoder.writeLong(Int64(index))
        try encodeGeneric(inner, id: node.branchIds[index], pool: pool, into: &encoder)
    case .record:
        if node.fieldWires.count != node.fields.count {
            cacheFieldWires(id: id, pool: pool)
        }
        let wires = node.fieldWires
        if wires.count == 1, wires[0].kind == .int {
            guard case .record(let fields) = value, fields.count == 1, case .int(let inner) = fields[0] else {
                throw typeMismatch("record")
            }
            encoder.writeInt(inner)
            return
        }
        guard case .record(let fields) = value, fields.count == wires.count else { throw typeMismatch("record") }
        for index in fields.indices {
            let wire = wires[index]
            let item = fields[index]
            switch wire.kind {
            case .null:
                break
            case .boolean:
                guard case .boolean(let inner) = item else { throw typeMismatch("boolean") }
                encoder.writeBool(inner)
            case .int:
                guard case .int(let inner) = item else { throw typeMismatch("int") }
                encoder.writeInt(inner)
            case .long:
                guard case .long(let inner) = item else { throw typeMismatch("long") }
                encoder.writeLong(inner)
            case .float:
                guard case .float(let inner) = item else { throw typeMismatch("float") }
                encoder.writeFloat(inner)
            case .double:
                guard case .double(let inner) = item else { throw typeMismatch("double") }
                encoder.writeDouble(inner)
            case .bytes:
                guard case .bytes(let inner) = item else { throw typeMismatch("bytes") }
                encoder.writeBytes(inner)
            case .string:
                guard case .string(let inner) = item else { throw typeMismatch("string") }
                encoder.writeString(inner)
            case .fixed:
                guard case .fixed(let inner) = item, inner.count == wire.fixedSize else { throw typeMismatch("fixed") }
                encoder.writeFixed(inner)
            case .enumeration:
                let symbols = pool.nodes[wire.typeId].symbols
                guard case .enumeration(let symbol) = item, let symbolIndex = symbols.firstIndex(of: symbol) else {
                    throw DecodeError(kind: .badEnum, offset: encoder.bytes.count, message: "symbol")
                }
                encoder.writeInt(Int32(symbolIndex))
            case .union:
                if wire.shape == 1 {
                    guard case .union(let branch, let payload) = item else { throw typeMismatch("union") }
                    if branch == 0 {
                        encoder.writeLong(0)
                    } else if branch == 1 {
                        guard case .string(let text) = payload else { throw typeMismatch("string") }
                        encoder.writeLong(1)
                        encoder.writeString(text)
                    } else {
                        throw DecodeError(kind: .badUnion, offset: encoder.bytes.count, message: "branch")
                    }
                } else {
                    try encodeGeneric(item, id: wire.typeId, pool: pool, into: &encoder)
                }
            case .array:
                if wire.childKind == .int {
                    guard case .array(let items) = item else { throw typeMismatch("array") }
                    if items.isEmpty {
                        encoder.writeLong(0)
                    } else {
                        encoder.writeLong(Int64(items.count))
                        for element in items {
                            guard case .int(let number) = element else { throw typeMismatch("int") }
                            encoder.writeInt(number)
                        }
                        encoder.writeBlockEnd()
                    }
                } else {
                    try encodeGeneric(item, id: wire.typeId, pool: pool, into: &encoder)
                }
            case .map:
                if wire.childKind == .string {
                    guard case .map(let pairs) = item else { throw typeMismatch("map") }
                    if pairs.isEmpty {
                        encoder.writeLong(0)
                    } else {
                        encoder.writeLong(Int64(pairs.count))
                        for (key, element) in pairs {
                            guard case .string(let text) = element else { throw typeMismatch("string") }
                            encoder.writeString(key)
                            encoder.writeString(text)
                        }
                        encoder.writeBlockEnd()
                    }
                } else {
                    try encodeGeneric(item, id: wire.typeId, pool: pool, into: &encoder)
                }
            case .record:
                if wire.shape == 2 {
                    guard case .record(let nested) = item, nested.count == 1, case .int(let number) = nested[0] else {
                        throw typeMismatch("record")
                    }
                    encoder.writeInt(number)
                } else {
                    try encodeGeneric(item, id: wire.typeId, pool: pool, into: &encoder)
                }
            }
        }
    }
}

func decodeGeneric(id: Int, pool: SchemaPool, from decoder: inout BinaryDecoder) throws -> AvroValue {
    let node = pool.nodes[id]
    switch node.kind {
    case .null:
        return .null
    case .boolean:
        return .boolean(try decoder.readBool())
    case .int:
        return .int(try decoder.readInt())
    case .long:
        return .long(try decoder.readLong())
    case .float:
        return .float(try decoder.readFloat())
    case .double:
        return .double(try decoder.readDouble())
    case .bytes:
        return .bytes(try decoder.readBytes())
    case .string:
        return .string(try decoder.readString())
    case .enumeration:
        let index = try decoder.readInt()
        guard index >= 0, Int(index) < node.symbols.count else {
            throw DecodeError(kind: .badEnum, offset: decoder.offset, message: node.name)
        }
        return .enumeration(node.symbols[Int(index)])
    case .fixed:
        return .fixed(try decoder.readFixed(node.size))
    case .array:
        let itemKind = pool.nodes[node.itemId].kind
        if itemKind == .int {
            var items: [AvroValue] = []
            while true {
                let count = try decoder.readBlockCount()
                if count == 0 { break }
                items.reserveCapacity(items.count + count)
                for _ in 0..<count {
                    items.append(.int(try decoder.readInt()))
                }
                try decoder.endBlock()
            }
            return .array(items)
        }
        var items: [AvroValue] = []
        while true {
            let count = try decoder.readBlockCount()
            if count == 0 { break }
            items.reserveCapacity(items.count + count)
            for _ in 0..<count {
                items.append(try decodeGeneric(id: node.itemId, pool: pool, from: &decoder))
            }
            try decoder.endBlock()
        }
        return .array(items)
    case .map:
        if pool.nodes[node.valueId].kind == .string {
            var pairs: [(String, AvroValue)] = []
            while true {
                let count = try decoder.readBlockCount()
                if count == 0 { break }
                pairs.reserveCapacity(pairs.count + count)
                for _ in 0..<count {
                    let key = try decoder.readString()
                    pairs.append((key, .string(try decoder.readString())))
                }
                try decoder.endBlock()
            }
            return .map(pairs)
        }
        var pairs: [(String, AvroValue)] = []
        while true {
            let count = try decoder.readBlockCount()
            if count == 0 { break }
            for _ in 0..<count {
                let key = try decoder.readString()
                let value = try decodeGeneric(id: node.valueId, pool: pool, from: &decoder)
                pairs.append((key, value))
            }
            try decoder.endBlock()
        }
        return .map(pairs)
    case .union:
        if node.branchIds.count == 2,
           pool.nodes[node.branchIds[0]].kind == .null,
           pool.nodes[node.branchIds[1]].kind == .string {
            let branch = try decoder.readLong()
            if branch == 0 { return .union(index: 0, value: .null) }
            if branch == 1 { return .union(index: 1, value: .string(try decoder.readString())) }
            throw DecodeError(kind: .badUnion, offset: decoder.offset, message: "index")
        }
        let raw = try decoder.readLong()
        guard raw >= 0, raw < Int64(node.branchIds.count) else {
            throw DecodeError(kind: .badUnion, offset: decoder.offset, message: "index")
        }
        let index = Int(raw)
        let value = try decodeGeneric(id: node.branchIds[index], pool: pool, from: &decoder)
        return .union(index: index, value: value)
    case .record:
        if node.fieldWires.count != node.fields.count {
            cacheFieldWires(id: id, pool: pool)
        }
        let wires = node.fieldWires
        if wires.count == 1, wires[0].kind == .int {
            return .record([.int(try decoder.readInt())])
        }
        var fields: [AvroValue] = []
        fields.reserveCapacity(wires.count)
        var failed = 0
        do {
            for index in wires.indices {
                failed = index
                let wire = wires[index]
                switch wire.kind {
                case .null:
                    fields.append(.null)
                case .boolean:
                    fields.append(.boolean(try decoder.readBool()))
                case .int:
                    fields.append(.int(try decoder.readInt()))
                case .long:
                    fields.append(.long(try decoder.readLong()))
                case .float:
                    fields.append(.float(try decoder.readFloat()))
                case .double:
                    fields.append(.double(try decoder.readDouble()))
                case .bytes:
                    fields.append(.bytes(try decoder.readBytes()))
                case .string:
                    fields.append(.string(try decoder.readString()))
                case .fixed:
                    fields.append(.fixed(try decoder.readFixed(wire.fixedSize)))
                case .enumeration:
                    let symbols = pool.nodes[wire.typeId].symbols
                    let symbolIndex = try decoder.readInt()
                    guard symbolIndex >= 0, Int(symbolIndex) < symbols.count else {
                        throw DecodeError(kind: .badEnum, offset: decoder.offset, message: "enum")
                    }
                    fields.append(.enumeration(symbols[Int(symbolIndex)]))
                case .union:
                    if wire.shape == 1 {
                        let branch = try decoder.readLong()
                        if branch == 0 {
                            fields.append(.union(index: 0, value: .null))
                        } else if branch == 1 {
                            fields.append(.union(index: 1, value: .string(try decoder.readString())))
                        } else {
                            throw DecodeError(kind: .badUnion, offset: decoder.offset, message: "index")
                        }
                    } else {
                        fields.append(try decodeGeneric(id: wire.typeId, pool: pool, from: &decoder))
                    }
                case .array:
                    if wire.childKind == .int {
                        var items: [AvroValue] = []
                        while true {
                            let count = try decoder.readBlockCount()
                            if count == 0 { break }
                            items.reserveCapacity(items.count + count)
                            for _ in 0..<count {
                                items.append(.int(try decoder.readInt()))
                            }
                            try decoder.endBlock()
                        }
                        fields.append(.array(items))
                    } else {
                        fields.append(try decodeGeneric(id: wire.typeId, pool: pool, from: &decoder))
                    }
                case .map:
                    if wire.childKind == .string {
                        var pairs: [(String, AvroValue)] = []
                        while true {
                            let count = try decoder.readBlockCount()
                            if count == 0 { break }
                            pairs.reserveCapacity(pairs.count + count)
                            for _ in 0..<count {
                                let key = try decoder.readString()
                                pairs.append((key, .string(try decoder.readString())))
                            }
                            try decoder.endBlock()
                        }
                        fields.append(.map(pairs))
                    } else {
                        fields.append(try decodeGeneric(id: wire.typeId, pool: pool, from: &decoder))
                    }
                case .record:
                    if wire.shape == 2 {
                        fields.append(.record([.int(try decoder.readInt())]))
                    } else {
                        fields.append(try decodeGeneric(id: wire.typeId, pool: pool, from: &decoder))
                    }
                }
            }
        } catch {
            throw wrapField(error, field: failed + 1)
        }
        return .record(fields)
    }
}

func skipGeneric(id: Int, pool: SchemaPool, decoder: inout BinaryDecoder) throws {
    let node = pool.nodes[id]
    switch node.kind {
    case .null:
        return
    case .boolean:
        _ = try decoder.readBool()
    case .int:
        _ = try decoder.readInt()
    case .long:
        _ = try decoder.readLong()
    case .float:
        try decoder.skip(4)
    case .double:
        try decoder.skip(8)
    case .bytes, .string:
        let count = try decoder.readCount()
        try decoder.skip(count)
    case .fixed:
        try decoder.skip(node.size)
    case .enumeration:
        _ = try decoder.readInt()
    case .array:
        while true {
            let count = try decoder.readBlockCount()
            if count == 0 { break }
            if decoder.blockEnd != nil {
                try decoder.advanceToBlockEnd()
            } else {
                for _ in 0..<count {
                    try skipGeneric(id: node.itemId, pool: pool, decoder: &decoder)
                }
            }
        }
    case .map:
        while true {
            let count = try decoder.readBlockCount()
            if count == 0 { break }
            if decoder.blockEnd != nil {
                try decoder.advanceToBlockEnd()
            } else {
                for _ in 0..<count {
                    let count = try decoder.readCount()
                    try decoder.skip(count)
                    try skipGeneric(id: node.valueId, pool: pool, decoder: &decoder)
                }
            }
        }
    case .union:
        let raw = try decoder.readLong()
        guard raw >= 0, raw < Int64(node.branchIds.count) else {
            throw DecodeError(kind: .badUnion, offset: decoder.offset, message: "skip")
        }
        try skipGeneric(id: node.branchIds[Int(raw)], pool: pool, decoder: &decoder)
    case .record:
        for field in node.fields {
            try skipGeneric(id: field.typeId, pool: pool, decoder: &decoder)
        }
    }
}

func typeMismatch(_ name: String) -> DecodeError {
    DecodeError(kind: .schema, offset: 0, message: "expected \(name)")
}

extension BinaryDecoder {
    mutating func advanceToBlockEnd() throws {
        guard let end = blockEnd else { return }
        if end < offset || end > bytes.count {
            throw DecodeError(kind: .badBlock, offset: offset, message: "block end")
        }
        offset = end
        blockEnd = nil
    }
}
