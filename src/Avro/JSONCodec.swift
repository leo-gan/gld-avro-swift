public func decodeDefault(_ text: String, pool: SchemaPool, typeId: Int) throws -> AvroValue {
    let json: JSONValue
    do {
        json = try parseJSON(text)
    } catch let error as JSONError {
        throw DecodeError(kind: .json, offset: error.offset, message: error.message)
    }
    return try decodeDefaultJSON(json, pool: pool, typeId: typeId)
}

func decodeDefaultJSON(_ json: JSONValue, pool: SchemaPool, typeId: Int) throws -> AvroValue {
    let node = pool.nodes[typeId]
    switch node.kind {
    case .null:
        guard case .null = json else { throw defaultMismatch("null") }
        return .null
    case .boolean:
        guard case .bool(let value) = json else { throw defaultMismatch("boolean") }
        return .boolean(value)
    case .int:
        guard case .number(let raw) = json, let value = jsonIntegral(raw) else { throw defaultMismatch("int") }
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw defaultMismatch("int range") }
        return .int(Int32(value))
    case .long:
        guard case .number(let raw) = json, let value = jsonIntegral(raw) else { throw defaultMismatch("long") }
        return .long(value)
    case .float:
        guard case .number(let raw) = json, let value = jsonDouble(raw) else { throw defaultMismatch("float") }
        return .float(Float(value))
    case .double:
        guard case .number(let raw) = json, let value = jsonDouble(raw) else { throw defaultMismatch("double") }
        return .double(value)
    case .string:
        guard case .string(let value) = json else { throw defaultMismatch("string") }
        return .string(value)
    case .bytes:
        guard case .string(let value) = json else { throw defaultMismatch("bytes") }
        return .bytes(try latin1Bytes(value))
    case .fixed:
        guard case .string(let value) = json else { throw defaultMismatch("fixed") }
        let bytes = try latin1Bytes(value)
        guard bytes.count == node.size else { throw defaultMismatch("fixed size") }
        return .fixed(bytes)
    case .enumeration:
        guard case .string(let symbol) = json, node.symbols.contains(symbol) else { throw defaultMismatch("enum") }
        return .enumeration(symbol)
    case .array:
        guard case .array(let items) = json else { throw defaultMismatch("array") }
        var values: [AvroValue] = []
        for item in items {
            values.append(try decodeDefaultJSON(item, pool: pool, typeId: node.itemId))
        }
        return .array(values)
    case .map:
        guard case .object(let pairs) = json else { throw defaultMismatch("map") }
        var values: [(String, AvroValue)] = []
        for (key, item) in pairs {
            values.append((key, try decodeDefaultJSON(item, pool: pool, typeId: node.valueId)))
        }
        return .map(values)
    case .union:
        guard let first = node.branchIds.first else { throw defaultMismatch("empty union") }
        return try decodeDefaultJSON(json, pool: pool, typeId: first)
    case .record:
        guard case .object(let pairs) = json else { throw defaultMismatch("record") }
        let map = dictionary(pairs)
        var fields: [AvroValue] = []
        for field in node.fields {
            if let present = map[field.name] {
                fields.append(try wrappedDefault(present, pool: pool, typeId: field.typeId))
            } else if field.hasDefault {
                fields.append(try defaultAsField(field, pool: pool))
            } else {
                throw defaultMismatch("missing field \(field.name)")
            }
        }
        return .record(fields)
    }
}

func wrappedDefault(_ json: JSONValue, pool: SchemaPool, typeId: Int) throws -> AvroValue {
    let inner = try decodeDefaultJSON(json, pool: pool, typeId: typeId)
    if pool.nodes[typeId].kind == .union {
        return .union(index: 0, value: inner)
    }
    return inner
}

func defaultMismatch(_ message: String) -> DecodeError {
    DecodeError(kind: .json, offset: 0, message: message)
}

func latin1Bytes(_ text: String) throws -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        if scalar.value > 255 {
            throw DecodeError(kind: .json, offset: 0, message: "byte out of ISO-8859-1")
        }
        bytes.append(UInt8(scalar.value))
    }
    return bytes
}

func jsonIntegral(_ raw: String) -> Int64? {
    if let value = jsonInteger(raw) { return value }
    guard let number = jsonDouble(raw), number.isFinite, number.rounded() == number else { return nil }
    if number < Double(Int64.min) || number > Double(Int64.max) { return nil }
    return Int64(number)
}

public func encodeJSON(_ value: AvroValue, pool: SchemaPool, root: Int? = nil) throws -> String {
    try encodeJSONValue(value, id: root ?? pool.root, pool: pool)
}

public func decodeJSON(_ text: String, pool: SchemaPool, root: Int? = nil) throws -> AvroValue {
    let json: JSONValue
    do {
        json = try parseJSON(text)
    } catch let error as JSONError {
        throw DecodeError(kind: .json, offset: error.offset, message: error.message)
    }
    return try decodeJSONValue(json, id: root ?? pool.root, pool: pool)
}

func encodeJSONValue(_ value: AvroValue, id: Int, pool: SchemaPool) throws -> String {
    let node = pool.nodes[id]
    switch node.kind {
    case .null:
        guard case .null = value else { throw typeMismatch("null") }
        return "null"
    case .boolean:
        guard case .boolean(let inner) = value else { throw typeMismatch("boolean") }
        return inner ? "true" : "false"
    case .int:
        guard case .int(let inner) = value else { throw typeMismatch("int") }
        return String(inner)
    case .long:
        guard case .long(let inner) = value else { throw typeMismatch("long") }
        return String(inner)
    case .float:
        guard case .float(let inner) = value else { throw typeMismatch("float") }
        guard let text = jsonNumberString(inner) else {
            throw DecodeError(kind: .badJSONNumber, offset: 0, message: "float")
        }
        return text
    case .double:
        guard case .double(let inner) = value else { throw typeMismatch("double") }
        guard let text = jsonNumberString(inner) else {
            throw DecodeError(kind: .badJSONNumber, offset: 0, message: "double")
        }
        return text
    case .string:
        guard case .string(let inner) = value else { throw typeMismatch("string") }
        return emitJSON(.string(inner))
    case .bytes:
        guard case .bytes(let inner) = value else { throw typeMismatch("bytes") }
        return emitJSON(.string(latin1String(inner)))
    case .fixed:
        guard case .fixed(let inner) = value, inner.count == node.size else { throw typeMismatch("fixed") }
        return emitJSON(.string(latin1String(inner)))
    case .enumeration:
        guard case .enumeration(let symbol) = value, node.symbols.contains(symbol) else {
            throw DecodeError(kind: .badEnum, offset: 0, message: node.name)
        }
        return emitJSON(.string(symbol))
    case .array:
        guard case .array(let items) = value else { throw typeMismatch("array") }
        var parts: [String] = []
        for item in items {
            parts.append(try encodeJSONValue(item, id: node.itemId, pool: pool))
        }
        return "[" + parts.joined(separator: ",") + "]"
    case .map:
        guard case .map(let pairs) = value else { throw typeMismatch("map") }
        var parts: [String] = []
        for (key, item) in pairs {
            parts.append(emitJSON(.string(key)) + ":" + (try encodeJSONValue(item, id: node.valueId, pool: pool)))
        }
        return "{" + parts.joined(separator: ",") + "}"
    case .record:
        guard case .record(let fields) = value, fields.count == node.fields.count else { throw typeMismatch("record") }
        var parts: [String] = []
        for (index, field) in node.fields.enumerated() {
            let body = try encodeJSONValue(fields[index], id: field.typeId, pool: pool)
            parts.append(emitJSON(.string(field.name)) + ":" + body)
        }
        return "{" + parts.joined(separator: ",") + "}"
    case .union:
        guard case .union(let index, let inner) = value, index >= 0, index < node.branchIds.count else {
            throw DecodeError(kind: .badUnion, offset: 0, message: "json union")
        }
        let branch = node.branchIds[index]
        if pool.nodes[branch].kind == .null {
            return "null"
        }
        let key = unionJSONKey(pool.nodes[branch])
        let body = try encodeJSONValue(inner, id: branch, pool: pool)
        return "{" + emitJSON(.string(key)) + ":" + body + "}"
    }
}

func decodeJSONValue(_ json: JSONValue, id: Int, pool: SchemaPool) throws -> AvroValue {
    let node = pool.nodes[id]
    switch node.kind {
    case .null:
        guard case .null = json else { throw DecodeError(kind: .json, offset: 0, message: "null") }
        return .null
    case .boolean:
        guard case .bool(let value) = json else { throw DecodeError(kind: .json, offset: 0, message: "boolean") }
        return .boolean(value)
    case .int:
        guard case .number(let raw) = json, let value = jsonIntegral(raw), value >= Int64(Int32.min), value <= Int64(Int32.max) else {
            throw DecodeError(kind: .json, offset: 0, message: "int")
        }
        return .int(Int32(value))
    case .long:
        guard case .number(let raw) = json, let value = jsonIntegral(raw) else {
            throw DecodeError(kind: .json, offset: 0, message: "long")
        }
        return .long(value)
    case .float:
        guard case .number(let raw) = json, let value = jsonDouble(raw) else {
            throw DecodeError(kind: .json, offset: 0, message: "float")
        }
        return .float(Float(value))
    case .double:
        guard case .number(let raw) = json, let value = jsonDouble(raw) else {
            throw DecodeError(kind: .json, offset: 0, message: "double")
        }
        return .double(value)
    case .string:
        guard case .string(let value) = json else { throw DecodeError(kind: .json, offset: 0, message: "string") }
        return .string(value)
    case .bytes:
        guard case .string(let value) = json else { throw DecodeError(kind: .json, offset: 0, message: "bytes") }
        return .bytes(try latin1Bytes(value))
    case .fixed:
        guard case .string(let value) = json else { throw DecodeError(kind: .json, offset: 0, message: "fixed") }
        let bytes = try latin1Bytes(value)
        guard bytes.count == node.size else { throw DecodeError(kind: .json, offset: 0, message: "fixed size") }
        return .fixed(bytes)
    case .enumeration:
        guard case .string(let symbol) = json, node.symbols.contains(symbol) else {
            throw DecodeError(kind: .badEnum, offset: 0, message: node.name)
        }
        return .enumeration(symbol)
    case .array:
        guard case .array(let items) = json else { throw DecodeError(kind: .json, offset: 0, message: "array") }
        var values: [AvroValue] = []
        for item in items {
            values.append(try decodeJSONValue(item, id: node.itemId, pool: pool))
        }
        return .array(values)
    case .map:
        guard case .object(let pairs) = json else { throw DecodeError(kind: .json, offset: 0, message: "map") }
        var values: [(String, AvroValue)] = []
        for (key, item) in pairs {
            values.append((key, try decodeJSONValue(item, id: node.valueId, pool: pool)))
        }
        return .map(values)
    case .record:
        guard case .object(let pairs) = json else { throw DecodeError(kind: .json, offset: 0, message: "record") }
        let map = dictionary(pairs)
        var fields: [AvroValue] = []
        for field in node.fields {
            if let present = map[field.name] {
                fields.append(try decodeJSONValue(present, id: field.typeId, pool: pool))
            } else if field.hasDefault {
                fields.append(try defaultAsField(field, pool: pool))
            } else {
                throw DecodeError(kind: .json, offset: 0, field: fields.count + 1, message: "missing \(field.name)")
            }
        }
        return .record(fields)
    case .union:
        if case .null = json {
            guard let index = node.branchIds.firstIndex(where: { pool.nodes[$0].kind == .null }) else {
                throw DecodeError(kind: .badUnion, offset: 0, message: "null")
            }
            return .union(index: index, value: .null)
        }
        guard case .object(let pairs) = json, pairs.count == 1 else {
            throw DecodeError(kind: .badUnion, offset: 0, message: "wrapper")
        }
        guard let index = unionBranch(named: pairs[0].0, branches: node.branchIds, pool: pool) else {
            throw DecodeError(kind: .badUnion, offset: 0, message: pairs[0].0)
        }
        let payload = try decodeJSONValue(pairs[0].1, id: node.branchIds[index], pool: pool)
        return .union(index: index, value: payload)
    }
}

func unionJSONKey(_ node: SchemaNode) -> String {
    switch node.kind {
    case .record, .enumeration, .fixed:
        return node.shortName.isEmpty ? shortName(of: node.name) : node.shortName
    default:
        return primitiveToken(node.kind) ?? "unknown"
    }
}

func unionBranch(named key: String, branches: [Int], pool: SchemaPool) -> Int? {
    for (index, id) in branches.enumerated() {
        let node = pool.nodes[id]
        if key.contains(".") {
            if node.name == key { return index }
            continue
        }
        if unionJSONKey(node) == key || node.name == key { return index }
    }
    return nil
}

func latin1String(_ bytes: [UInt8]) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(bytes.count)
    for byte in bytes {
        scalars.append(UnicodeScalar(UInt32(byte))!)
    }
    return String(scalars)
}
