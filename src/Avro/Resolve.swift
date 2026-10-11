struct ResolveKey: Hashable {
    var writerPool: ObjectIdentifier
    var readerPool: ObjectIdentifier
    var writer: Int
    var reader: Int
}

final class ResolveState {
    var visiting: Set<ResolveKey> = []

    func canResolve(_ writerId: Int, _ writer: SchemaPool, _ readerId: Int, _ reader: SchemaPool) -> Bool {
        let key = ResolveKey(
            writerPool: ObjectIdentifier(writer),
            readerPool: ObjectIdentifier(reader),
            writer: writerId,
            reader: readerId
        )
        if visiting.contains(key) { return true }
        visiting.insert(key)
        defer { visiting.remove(key) }
        let left = writer.nodes[writerId]
        let right = reader.nodes[readerId]
        if left.kind == .union && right.kind == .union {
            for branch in left.branchIds {
                if firstReaderBranch(branch, writer, right, reader) == nil { return false }
            }
            return true
        }
        if left.kind == .union {
            return left.branchIds.contains { canResolve($0, writer, readerId, reader) }
        }
        if right.kind == .union {
            return firstReaderBranch(writerId, writer, right, reader) != nil
        }
        switch (left.kind, right.kind) {
        case (.record, .record), (.enumeration, .enumeration), (.fixed, .fixed):
            guard namedMatch(left, right) else { return false }
            if left.kind != .record { return true }
            var used = [Bool](repeating: false, count: left.fields.count)
            for field in right.fields {
                var found: Int?
                for (index, writerField) in left.fields.enumerated() where !used[index] {
                    if fieldsMatch(writerField, field) {
                        found = index
                        break
                    }
                }
                if let found {
                    used[found] = true
                    if !canResolve(left.fields[found].typeId, writer, field.typeId, reader) { return false }
                } else if !field.hasDefault {
                    return false
                }
            }
            return true
        case (.array, .array):
            return canResolve(left.itemId, writer, right.itemId, reader)
        case (.map, .map):
            return canResolve(left.valueId, writer, right.valueId, reader)
        default:
            return promote(left.kind, right.kind) != nil
        }
    }

    func firstReaderBranch(_ writerId: Int, _ writer: SchemaPool, _ readerUnion: SchemaNode, _ reader: SchemaPool) -> Int? {
        for (index, branch) in readerUnion.branchIds.enumerated() {
            if canResolve(writerId, writer, branch, reader) { return index }
        }
        return nil
    }

    func resolve(
        _ writerId: Int,
        _ writer: SchemaPool,
        _ readerId: Int,
        _ reader: SchemaPool,
        _ decoder: inout BinaryDecoder
    ) throws -> AvroValue {
        let left = writer.nodes[writerId]
        let right = reader.nodes[readerId]
        if left.kind == .union && right.kind == .union {
            let index = try readUnionIndex(left, &decoder)
            guard let readerIndex = firstReaderBranch(left.branchIds[index], writer, right, reader) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "union branch")
            }
            let value = try resolve(left.branchIds[index], writer, right.branchIds[readerIndex], reader, &decoder)
            return .union(index: readerIndex, value: value)
        }
        if left.kind == .union {
            let index = try readUnionIndex(left, &decoder)
            let branch = left.branchIds[index]
            guard canResolve(branch, writer, readerId, reader) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "union to value")
            }
            return try resolve(branch, writer, readerId, reader, &decoder)
        }
        if right.kind == .union {
            guard let readerIndex = firstReaderBranch(writerId, writer, right, reader) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "value to union")
            }
            let value = try resolve(writerId, writer, right.branchIds[readerIndex], reader, &decoder)
            return .union(index: readerIndex, value: value)
        }
        switch (left.kind, right.kind) {
        case (.record, .record):
            guard namedMatch(left, right) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "record \(left.name)")
            }
            return try resolveRecord(left, writer, right, reader, &decoder)
        case (.enumeration, .enumeration):
            guard namedMatch(left, right) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "enum \(left.name)")
            }
            let index = try decoder.readInt()
            guard index >= 0, Int(index) < left.symbols.count else {
                throw DecodeError(kind: .badEnum, offset: decoder.offset, message: left.name)
            }
            let symbol = left.symbols[Int(index)]
            if right.symbols.contains(symbol) {
                return .enumeration(symbol)
            }
            if !right.enumDefault.isEmpty {
                return .enumeration(right.enumDefault)
            }
            throw DecodeError(kind: .resolve, offset: decoder.offset, message: "symbol \(symbol)")
        case (.fixed, .fixed):
            guard namedMatch(left, right) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "fixed \(left.name)")
            }
            return .fixed(try decoder.readFixed(left.size))
        case (.array, .array):
            var items: [AvroValue] = []
            while true {
                let count = try decoder.readBlockCount()
                if count == 0 { break }
                for _ in 0..<count {
                    items.append(try resolve(left.itemId, writer, right.itemId, reader, &decoder))
                }
                try decoder.endBlock()
            }
            return .array(items)
        case (.map, .map):
            var pairs: [(String, AvroValue)] = []
            while true {
                let count = try decoder.readBlockCount()
                if count == 0 { break }
                for _ in 0..<count {
                    let key = try decoder.readString()
                    let value = try resolve(left.valueId, writer, right.valueId, reader, &decoder)
                    pairs.append((key, value))
                }
                try decoder.endBlock()
            }
            return .map(pairs)
        default:
            guard let kind = promote(left.kind, right.kind) else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, message: "\(left.kind) to \(right.kind)")
            }
            return try readPromoted(kind, from: left.kind, decoder: &decoder)
        }
    }

    func resolveRecord(
        _ left: SchemaNode,
        _ writer: SchemaPool,
        _ right: SchemaNode,
        _ reader: SchemaPool,
        _ decoder: inout BinaryDecoder
    ) throws -> AvroValue {
        var used = [Bool](repeating: false, count: right.fields.count)
        var plan: [Int?] = []
        plan.reserveCapacity(left.fields.count)
        for field in left.fields {
            var found: Int? = nil
            for (index, readerField) in right.fields.enumerated() where !used[index] {
                if fieldsMatch(field, readerField) {
                    found = index
                    break
                }
            }
            if let found { used[found] = true }
            plan.append(found)
        }
        var values = [AvroValue?](repeating: nil, count: right.fields.count)
        for (index, field) in left.fields.enumerated() {
            if let readerIndex = plan[index] {
                do {
                    values[readerIndex] = try resolve(field.typeId, writer, right.fields[readerIndex].typeId, reader, &decoder)
                } catch {
                    throw wrapField(error, field: readerIndex + 1)
                }
            } else {
                try skipGeneric(id: field.typeId, pool: writer, decoder: &decoder)
            }
        }
        for (index, field) in right.fields.enumerated() where values[index] == nil {
            guard field.hasDefault else {
                throw DecodeError(kind: .resolve, offset: decoder.offset, field: index + 1, message: "missing \(field.name)")
            }
            values[index] = try defaultAsField(field, pool: reader)
        }
        return .record(values.map { $0! })
    }
}

enum PromoteKind {
    case copy(SchemaKind)
    case intToLong
    case intToFloat
    case intToDouble
    case longToFloat
    case longToDouble
    case floatToDouble
    case stringToBytes
    case bytesToString
}

func promote(_ writer: SchemaKind, _ reader: SchemaKind) -> PromoteKind? {
    if writer == reader, writer != .record && writer != .enumeration && writer != .fixed
        && writer != .array && writer != .map && writer != .union {
        return .copy(writer)
    }
    switch (writer, reader) {
    case (.int, .long): return .intToLong
    case (.int, .float): return .intToFloat
    case (.int, .double): return .intToDouble
    case (.long, .float): return .longToFloat
    case (.long, .double): return .longToDouble
    case (.float, .double): return .floatToDouble
    case (.string, .bytes): return .stringToBytes
    case (.bytes, .string): return .bytesToString
    default: return nil
    }
}

func readPromoted(_ kind: PromoteKind, from writer: SchemaKind, decoder: inout BinaryDecoder) throws -> AvroValue {
    switch kind {
    case .copy(let schemaKind):
        switch schemaKind {
        case .null: return .null
        case .boolean: return .boolean(try decoder.readBool())
        case .int: return .int(try decoder.readInt())
        case .long: return .long(try decoder.readLong())
        case .float: return .float(try decoder.readFloat())
        case .double: return .double(try decoder.readDouble())
        case .bytes: return .bytes(try decoder.readBytes())
        case .string: return .string(try decoder.readString())
        default:
            throw DecodeError(kind: .resolve, offset: decoder.offset, message: "copy")
        }
    case .intToLong:
        return .long(Int64(try decoder.readInt()))
    case .intToFloat:
        return .float(Float(try decoder.readInt()))
    case .intToDouble:
        return .double(Double(try decoder.readInt()))
    case .longToFloat:
        return .float(Float(try decoder.readLong()))
    case .longToDouble:
        return .double(Double(try decoder.readLong()))
    case .floatToDouble:
        return .double(Double(try decoder.readFloat()))
    case .stringToBytes:
        let text = try decoder.readString()
        return .bytes(Array(text.utf8))
    case .bytesToString:
        let raw = try decoder.readBytes()
        guard let text = utf8String(raw) else {
            throw DecodeError(kind: .badUTF8, offset: decoder.offset, message: "bytes as string")
        }
        return .string(text)
    }
}

func namedMatch(_ writer: SchemaNode, _ reader: SchemaNode) -> Bool {
    if writer.kind != reader.kind { return false }
    if writer.kind == .fixed && writer.size != reader.size { return false }
    let writerShort = writer.shortName.isEmpty ? shortName(of: writer.name) : writer.shortName
    let readerShort = reader.shortName.isEmpty ? shortName(of: reader.name) : reader.shortName
    if !writerShort.isEmpty && writerShort == readerShort { return true }
    let qualified = writer.namespace.isEmpty ? writerShort : writer.namespace + "." + writerShort
    let candidates: Set<String> = [writer.name, writerShort, qualified]
    for alias in reader.aliases where candidates.contains(alias) {
        return true
    }
    return false
}

func fieldsMatch(_ writer: FieldDesc, _ reader: FieldDesc) -> Bool {
    if writer.name == reader.name { return true }
    if reader.aliases.contains(writer.name) { return true }
    if writer.aliases.contains(reader.name) { return true }
    for alias in reader.aliases where writer.aliases.contains(alias) { return true }
    return false
}

func writerField(for readerField: FieldDesc, in fields: [FieldDesc]) -> Int? {
    for (index, field) in fields.enumerated() where fieldsMatch(field, readerField) {
        return index
    }
    return nil
}

func readUnionIndex(_ node: SchemaNode, _ decoder: inout BinaryDecoder) throws -> Int {
    let raw = try decoder.readLong()
    guard raw >= 0, raw < Int64(node.branchIds.count) else {
        throw DecodeError(kind: .badUnion, offset: decoder.offset, message: "index")
    }
    return Int(raw)
}

public func decodeResolving(
    _ bytes: [UInt8],
    writer: SchemaPool,
    writerRoot: Int? = nil,
    reader: SchemaPool,
    readerRoot: Int? = nil
) throws -> AvroValue {
    let writerId = writerRoot ?? writer.root
    let readerId = readerRoot ?? reader.root
    let state = ResolveState()
    guard state.canResolve(writerId, writer, readerId, reader) else {
        throw DecodeError(kind: .resolve, offset: 0, message: "schemas do not match")
    }
    var decoder = BinaryDecoder(bytes)
    return try state.resolve(writerId, writer, readerId, reader, &decoder)
}

func defaultAsField(_ field: FieldDesc, pool: SchemaPool) throws -> AvroValue {
    let inner = try decodeDefault(field.defaultJSON, pool: pool, typeId: field.typeId)
    if pool.nodes[field.typeId].kind == .union {
        return .union(index: 0, value: inner)
    }
    return inner
}
