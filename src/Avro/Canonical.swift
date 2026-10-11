public func canonicalForm(_ pool: SchemaPool, root: Int? = nil) -> String {
    var seen = Set<Int>()
    let value = canonicalValue(root ?? pool.root, pool: pool, seen: &seen)
    return emitJSON(value)
}

func canonicalValue(_ id: Int, pool: SchemaPool, seen: inout Set<Int>) -> JSONValue {
    let node = pool.nodes[id]
    switch node.kind {
    case .null, .boolean, .int, .long, .float, .double, .bytes, .string:
        return .string(primitiveToken(node.kind)!)
    case .array:
        return .object([
            ("type", .string("array")),
            ("items", canonicalValue(node.itemId, pool: pool, seen: &seen)),
        ])
    case .map:
        return .object([
            ("type", .string("map")),
            ("values", canonicalValue(node.valueId, pool: pool, seen: &seen)),
        ])
    case .union:
        return .array(node.branchIds.map { canonicalValue($0, pool: pool, seen: &seen) })
    case .record, .enumeration, .fixed:
        if seen.contains(id) {
            return .string(node.name)
        }
        seen.insert(id)
        let typeName = node.kind == .enumeration ? "enum" : (node.kind == .fixed ? "fixed" : (node.isError ? "error" : "record"))
        var pairs: [(String, JSONValue)] = [
            ("name", .string(node.name)),
            ("type", .string(typeName)),
        ]
        if node.kind == .record {
            let fields: [JSONValue] = node.fields.map { field in
                .object([
                    ("name", .string(field.name)),
                    ("type", canonicalValue(field.typeId, pool: pool, seen: &seen)),
                ])
            }
            pairs.append(("fields", .array(fields)))
        } else if node.kind == .enumeration {
            pairs.append(("symbols", .array(node.symbols.map { .string($0) })))
        } else {
            pairs.append(("size", .number(String(node.size))))
        }
        return .object(pairs)
    }
}

public func emitSchemaJSON(_ pool: SchemaPool, root: Int? = nil) -> String {
    var seen = Set<Int>()
    return emitSchemaBody(root ?? pool.root, pool: pool, seen: &seen)
}

func emitSchemaBody(_ id: Int, pool: SchemaPool, seen: inout Set<Int>) -> String {
    let node = pool.nodes[id]
    switch node.kind {
    case .null, .boolean, .int, .long, .float, .double, .bytes, .string:
        if node.logicalType.isEmpty && node.attributes.isEmpty && node.doc.isEmpty && node.aliases.isEmpty {
            return "\"\(primitiveToken(node.kind)!)\""
        }
        return emitTypedObject(node, type: primitiveToken(node.kind)!, extra: [], pool: pool, seen: &seen)
    case .array:
        let items = emitSchemaBody(node.itemId, pool: pool, seen: &seen)
        return emitTypedObject(node, type: "array", extra: [("items", items)], pool: pool, seen: &seen)
    case .map:
        let values = emitSchemaBody(node.valueId, pool: pool, seen: &seen)
        return emitTypedObject(node, type: "map", extra: [("values", values)], pool: pool, seen: &seen)
    case .union:
        let parts = node.branchIds.map { emitSchemaBody($0, pool: pool, seen: &seen) }
        return "[" + parts.joined(separator: ",") + "]"
    case .record, .enumeration, .fixed:
        if seen.contains(id) {
            return "\"\(escapeJSON(node.name))\""
        }
        seen.insert(id)
        let typeName = node.kind == .enumeration ? "enum" : (node.kind == .fixed ? "fixed" : (node.isError ? "error" : "record"))
        var extra: [(String, String)] = []
        if !node.namespace.isEmpty {
            extra.append(("namespace", "\"\(escapeJSON(node.namespace))\""))
        }
        if node.kind == .record {
            var fields: [String] = []
            for field in node.fields {
                var parts = ["\"name\":\"\(escapeJSON(field.name))\"", "\"type\":\(emitSchemaBody(field.typeId, pool: pool, seen: &seen))"]
                if !field.doc.isEmpty { parts.append("\"doc\":\(emitJSON(.string(field.doc)))") }
                if field.hasDefault { parts.append("\"default\":\(field.defaultJSON)") }
                if !field.aliases.isEmpty {
                    parts.append("\"aliases\":\(emitJSON(.array(field.aliases.map { .string($0) })))")
                }
                if field.order == 1 { parts.append("\"order\":\"descending\"") }
                if field.order == 2 { parts.append("\"order\":\"ignore\"") }
                fields.append("{" + parts.joined(separator: ",") + "}")
            }
            extra.append(("fields", "[" + fields.joined(separator: ",") + "]"))
        } else if node.kind == .enumeration {
            extra.append(("symbols", emitJSON(.array(node.symbols.map { .string($0) }))))
            if !node.enumDefault.isEmpty {
                extra.append(("default", emitJSON(.string(node.enumDefault))))
            }
        } else {
            extra.append(("size", String(node.size)))
        }
        return emitTypedObject(node, type: typeName, extra: extra, pool: pool, seen: &seen, named: true)
    }
}

func emitTypedObject(
    _ node: SchemaNode,
    type: String,
    extra: [(String, String)],
    pool: SchemaPool,
    seen: inout Set<Int>,
    named: Bool = false
) -> String {
    var parts: [String] = []
    parts.append("\"type\":\"\(type)\"")
    if named {
        parts.append("\"name\":\"\(escapeJSON(node.shortName.isEmpty ? node.name : node.shortName))\"")
    }
    for (key, raw) in extra {
        parts.append("\"\(key)\":\(raw)")
    }
    if !node.aliases.isEmpty && named {
        parts.append("\"aliases\":\(emitJSON(.array(node.aliases.map { .string($0) })))")
    }
    if !node.doc.isEmpty {
        parts.append("\"doc\":\(emitJSON(.string(node.doc)))")
    }
    if !node.logicalType.isEmpty {
        parts.append("\"logicalType\":\(emitJSON(.string(node.logicalType)))")
    }
    for key in node.attributes.keys.sorted() {
        parts.append("\"\(escapeJSON(key))\":\(node.attributes[key]!)")
    }
    return "{" + parts.joined(separator: ",") + "}"
}

func escapeJSON(_ text: String) -> String {
    var out = ""
    emitJSON(.string(text), into: &out)
    if out.count >= 2 { return String(out.dropFirst().dropLast()) }
    return out
}
