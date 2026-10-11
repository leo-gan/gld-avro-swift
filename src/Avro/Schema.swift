public enum SchemaKind: Int, Equatable, Sendable {
    case null = 0
    case boolean = 1
    case int = 2
    case long = 3
    case float = 4
    case double = 5
    case bytes = 6
    case string = 7
    case record = 8
    case enumeration = 9
    case array = 10
    case map = 11
    case union = 12
    case fixed = 13
}

struct FieldWire {
    var kind: SchemaKind
    var typeId: Int
    var fixedSize: Int
    var childKind: SchemaKind
    var shape: Int
}

func cacheFieldWires(id: Int, pool: SchemaPool) {
    let node = pool.nodes[id]
    var wires: [FieldWire] = []
    wires.reserveCapacity(node.fields.count)
    for field in node.fields {
        let child = pool.nodes[field.typeId]
        var fixedSize = 0
        var childKind = SchemaKind.null
        var shape = 0
        switch child.kind {
        case .fixed:
            fixedSize = child.size
        case .array:
            if child.itemId >= 0 {
                childKind = pool.nodes[child.itemId].kind
            }
        case .map:
            if child.valueId >= 0 {
                childKind = pool.nodes[child.valueId].kind
            }
        case .union:
            if child.branchIds.count == 2,
               pool.nodes[child.branchIds[0]].kind == .null,
               pool.nodes[child.branchIds[1]].kind == .string {
                shape = 1
            }
        case .record:
            if child.fields.count == 1, child.fieldKinds.first == .int {
                shape = 2
            }
        default:
            break
        }
        wires.append(FieldWire(
            kind: child.kind,
            typeId: field.typeId,
            fixedSize: fixedSize,
            childKind: childKind,
            shape: shape
        ))
    }
    node.fieldWires = wires
    node.fieldKinds = wires.map { $0.kind }
}

public struct FieldDesc: Equatable, Sendable {
    public var name: String
    public var typeId: Int
    public var hasDefault: Bool
    public var defaultJSON: String
    public var aliases: [String]
    public var doc: String
    public var order: Int

    public init(
        name: String,
        typeId: Int,
        hasDefault: Bool = false,
        defaultJSON: String = "",
        aliases: [String] = [],
        doc: String = "",
        order: Int = 0
    ) {
        self.name = name
        self.typeId = typeId
        self.hasDefault = hasDefault
        self.defaultJSON = defaultJSON
        self.aliases = aliases
        self.doc = doc
        self.order = order
    }
}

public final class SchemaNode {
    public var kind: SchemaKind
    public var name: String
    public var namespace: String
    public var aliases: [String]
    public var doc: String
    public var logicalType: String
    public var symbols: [String]
    public var enumDefault: String
    public var fields: [FieldDesc]
    public var itemId: Int
    public var valueId: Int
    public var branchIds: [Int]
    public var size: Int
    public var attributes: [String: String]
    public var shortName: String
    public var isError: Bool
    public var complete: Bool
    public var fieldKinds: [SchemaKind]
    var fieldWires: [FieldWire]

    public init(
        kind: SchemaKind,
        name: String = "",
        namespace: String = "",
        aliases: [String] = [],
        doc: String = "",
        logicalType: String = "",
        symbols: [String] = [],
        enumDefault: String = "",
        fields: [FieldDesc] = [],
        itemId: Int = -1,
        valueId: Int = -1,
        branchIds: [Int] = [],
        size: Int = 0,
        attributes: [String: String] = [:],
        shortName: String = "",
        isError: Bool = false,
        complete: Bool = false,
        fieldKinds: [SchemaKind] = []
    ) {
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.aliases = aliases
        self.doc = doc
        self.logicalType = logicalType
        self.symbols = symbols
        self.enumDefault = enumDefault
        self.fields = fields
        self.itemId = itemId
        self.valueId = valueId
        self.branchIds = branchIds
        self.size = size
        self.attributes = attributes
        self.shortName = shortName
        self.isError = isError
        self.complete = complete
        self.fieldKinds = fieldKinds
        self.fieldWires = []
    }

    public static func make(_ kind: SchemaKind) -> SchemaNode {
        SchemaNode(kind: kind)
    }

    public func copy() -> SchemaNode {
        let copy = SchemaNode(
            kind: kind,
            name: name,
            namespace: namespace,
            aliases: aliases,
            doc: doc,
            logicalType: logicalType,
            symbols: symbols,
            enumDefault: enumDefault,
            fields: fields,
            itemId: itemId,
            valueId: valueId,
            branchIds: branchIds,
            size: size,
            attributes: attributes,
            shortName: shortName,
            isError: isError,
            complete: complete,
            fieldKinds: fieldKinds
        )
        copy.fieldWires = fieldWires
        return copy
    }
}

public final class SchemaPool {
    public var nodes: [SchemaNode]
    public var byName: [String: Int]
    public var root: Int
    public var originalJSON: String

    public init() {
        nodes = []
        byName = [:]
        root = -1
        originalJSON = ""
    }

    public func node(_ id: Int) -> SchemaNode { nodes[id] }

    @discardableResult
    public func add(_ node: SchemaNode) -> Int {
        let id = nodes.count
        nodes.append(node)
        return id
    }
}

let primitiveNames: Set<String> = [
    "null", "boolean", "int", "long", "float", "double", "bytes", "string",
]

func kindOfPrimitive(_ name: String) -> SchemaKind? {
    switch name {
    case "null": return .null
    case "boolean": return .boolean
    case "int": return .int
    case "long": return .long
    case "float": return .float
    case "double": return .double
    case "bytes": return .bytes
    case "string": return .string
    default: return nil
    }
}

func primitiveToken(_ kind: SchemaKind) -> String? {
    switch kind {
    case .null: return "null"
    case .boolean: return "boolean"
    case .int: return "int"
    case .long: return "long"
    case .float: return "float"
    case .double: return "double"
    case .bytes: return "bytes"
    case .string: return "string"
    case .array: return "array"
    case .map: return "map"
    case .record: return "record"
    case .enumeration: return "enum"
    case .fixed: return "fixed"
    case .union: return nil
    }
}

func isUnqualifiedName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first else { return false }
    func okStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
    }
    func okRest(_ scalar: Unicode.Scalar) -> Bool {
        okStart(scalar) || (scalar >= "0" && scalar <= "9")
    }
    if !okStart(first) { return false }
    for scalar in name.unicodeScalars.dropFirst() where !okRest(scalar) {
        return false
    }
    return true
}

func isFullName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    if parts.isEmpty { return false }
    return parts.allSatisfy { isUnqualifiedName(String($0)) }
}

struct ParsedName {
    var full: String
    var short: String
    var space: String
}

func parseFullName(name: String, namespace: String?, enclosing: String) throws -> ParsedName {
    if name.isEmpty {
        throw SchemaError(message: "name must not be empty")
    }
    let full: String
    if name.contains(".") || namespace == "" || (namespace == nil && enclosing.isEmpty) {
        full = name
    } else {
        let ns = (namespace?.isEmpty == false) ? namespace! : enclosing
        full = ns.isEmpty ? name : ns + "." + name
    }
    guard isFullName(full) else {
        throw SchemaError(message: "illegal name \(full)")
    }
    if primitiveNames.contains(full) {
        throw SchemaError(message: "\(full) is a reserved type name")
    }
    let parts = full.split(separator: ".")
    let short = String(parts.last!)
    let space = parts.count > 1 ? parts.dropLast().joined(separator: ".") : ""
    return ParsedName(full: full, short: short, space: space)
}

public func parseAvsc(_ text: String) throws -> SchemaPool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: JSONValue
    do {
        json = try parseJSON(trimmed)
    } catch let error as JSONError {
        throw SchemaError(message: error.message, path: "offset \(error.offset)")
    }
    let pool = SchemaPool()
    pool.originalJSON = trimmed
    let parser = AvscParser(pool: pool)
    try parser.prescan(json, enclosing: "", path: "$")
    pool.root = try parser.parseSchema(json, enclosing: "", path: "$")
    try parser.validateDefaults()
    for node in pool.nodes where !node.complete && isNamed(node.kind) {
        throw SchemaError(message: "undefined name \(node.name)")
    }
    return pool
}

func isNamed(_ kind: SchemaKind) -> Bool {
    kind == .record || kind == .enumeration || kind == .fixed
}

final class AvscParser {
    let pool: SchemaPool
    var barePrimitives: [SchemaKind: Int] = [:]

    init(pool: SchemaPool) {
        self.pool = pool
    }

    func prescan(_ node: JSONValue, enclosing: String, path: String) throws {
        switch node {
        case .array(let items):
            for (index, item) in items.enumerated() {
                try prescan(item, enclosing: enclosing, path: "\(path)[\(index)]")
            }
        case .object(let pairs):
            let map = dictionary(pairs)
            guard let typeValue = map["type"] else { return }
            if case .string(let typeName) = typeValue,
               typeName == "record" || typeName == "error" || typeName == "enum" || typeName == "fixed" {
                guard case .string(let rawName) = map["name"] ?? .null else {
                    throw SchemaError(message: "named type requires a name", path: path)
                }
                let ns = stringField(map["namespace"])
                let parsed = try parseFullName(name: rawName, namespace: ns, enclosing: enclosing)
                if pool.byName[parsed.full] == nil {
                    let placeholder = SchemaNode.make(typeName == "enum" ? .enumeration : (typeName == "fixed" ? .fixed : .record))
                    placeholder.name = parsed.full
                    placeholder.shortName = parsed.short
                    placeholder.namespace = parsed.space
                    placeholder.isError = typeName == "error"
                    let id = pool.add(placeholder)
                    pool.byName[parsed.full] = id
                }
                if let fields = map["fields"], case .array(let fieldNodes) = fields {
                    for (index, field) in fieldNodes.enumerated() {
                        guard case .object(let fieldPairs) = field else { continue }
                        let fieldMap = dictionary(fieldPairs)
                        if let fieldType = fieldMap["type"] {
                            try prescan(fieldType, enclosing: parsed.space, path: "\(path).fields[\(index)].type")
                        }
                    }
                }
                return
            }
            try prescan(typeValue, enclosing: enclosing, path: path + ".type")
            if case .string(let typeName) = typeValue, typeName == "array", let items = map["items"] {
                try prescan(items, enclosing: enclosing, path: path + ".items")
            }
            if case .string(let typeName) = typeValue, typeName == "map", let values = map["values"] {
                try prescan(values, enclosing: enclosing, path: path + ".values")
            }
        default:
            break
        }
    }

    func parseSchema(_ node: JSONValue, enclosing: String, path: String) throws -> Int {
        switch node {
        case .string(let name):
            if let kind = kindOfPrimitive(name) {
                return internPrimitive(kind)
            }
            let parsed = try parseFullName(name: name, namespace: nil, enclosing: enclosing)
            guard let id = pool.byName[parsed.full] else {
                throw SchemaError(message: "unknown name \(parsed.full)", path: path)
            }
            return id
        case .array(let items):
            if items.isEmpty {
                throw SchemaError(message: "union must not be empty", path: path)
            }
            var branches: [Int] = []
            branches.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                let id = try parseSchema(item, enclosing: enclosing, path: "\(path)[\(index)]")
                let resolved = pool.nodes[id]
                if resolved.kind == .union {
                    throw SchemaError(message: "unions cannot contain other unions", path: "\(path)[\(index)]")
                }
                branches.append(id)
            }
            try checkUnionBranches(branches, path: path)
            let schema = SchemaNode.make(.union)
            schema.branchIds = branches
            schema.complete = true
            return pool.add(schema)
        case .object(let pairs):
            return try parseObject(pairs, enclosing: enclosing, path: path)
        default:
            throw SchemaError(message: "schema must be a string, array, or object", path: path)
        }
    }

    func parseObject(_ pairs: [(String, JSONValue)], enclosing: String, path: String) throws -> Int {
        let map = dictionary(pairs)
        guard let typeValue = map["type"] else {
            throw SchemaError(message: "schema object requires type", path: path)
        }
        if case .string(let typeName) = typeValue {
            switch typeName {
            case "record", "error":
                return try parseRecord(map, pairs: pairs, enclosing: enclosing, path: path, isError: typeName == "error")
            case "enum":
                return try parseEnum(map, pairs: pairs, enclosing: enclosing, path: path)
            case "fixed":
                return try parseFixed(map, pairs: pairs, enclosing: enclosing, path: path)
            case "array":
                guard let items = map["items"] else {
                    throw SchemaError(message: "array requires items", path: path)
                }
                let itemId = try parseSchema(items, enclosing: enclosing, path: path + ".items")
                let schema = SchemaNode.make(.array)
                schema.itemId = itemId
                schema.logicalType = stringField(map["logicalType"]) ?? ""
                schema.attributes = extraAttributes(pairs, known: schemaKeys)
                schema.complete = true
                return pool.add(schema)
            case "map":
                guard let values = map["values"] else {
                    throw SchemaError(message: "map requires values", path: path)
                }
                let valueId = try parseSchema(values, enclosing: enclosing, path: path + ".values")
                let schema = SchemaNode.make(.map)
                schema.valueId = valueId
                schema.logicalType = stringField(map["logicalType"]) ?? ""
                schema.attributes = extraAttributes(pairs, known: schemaKeys)
                schema.complete = true
                return pool.add(schema)
            case "null", "boolean", "int", "long", "float", "double", "bytes", "string":
                let logical = stringField(map["logicalType"]) ?? ""
                let extras = extraAttributes(pairs, known: schemaKeys.union(["type", "logicalType"]))
                if logical.isEmpty && extras.isEmpty && map["doc"] == nil && map["aliases"] == nil {
                    return internPrimitive(kindOfPrimitive(typeName)!)
                }
                let schema = SchemaNode.make(kindOfPrimitive(typeName)!)
                schema.name = typeName
                schema.shortName = typeName
                schema.logicalType = logical
                schema.doc = stringField(map["doc"]) ?? ""
                schema.aliases = try stringList(map["aliases"], path: path + ".aliases")
                schema.attributes = extras
                schema.complete = true
                return pool.add(schema)
            default:
                break
            }
        }
        let nested = try parseSchema(typeValue, enclosing: enclosing, path: path + ".type")
        let logical = stringField(map["logicalType"]) ?? ""
        let extras = extraAttributes(pairs, known: ["type", "logicalType", "doc", "aliases"])
        if logical.isEmpty && extras.isEmpty {
            return nested
        }
        let schema = pool.nodes[nested].copy()
        if schema.logicalType.isEmpty { schema.logicalType = logical }
        if schema.attributes.isEmpty { schema.attributes = extras }
        if schema.doc.isEmpty { schema.doc = stringField(map["doc"]) ?? "" }
        schema.complete = true
        let id = pool.add(schema)
        return id
    }

    func parseRecord(
        _ map: [String: JSONValue],
        pairs: [(String, JSONValue)],
        enclosing: String,
        path: String,
        isError: Bool
    ) throws -> Int {
        guard case .string(let rawName) = map["name"] ?? .null else {
            throw SchemaError(message: "record requires name", path: path)
        }
        let parsed = try parseFullName(name: rawName, namespace: stringField(map["namespace"]), enclosing: enclosing)
        guard case .array(let fieldNodes) = map["fields"] ?? .null else {
            throw SchemaError(message: "record requires fields", path: path)
        }
        let id = try claim(parsed, kind: .record, isError: isError, path: path)
        var fields: [FieldDesc] = []
        var seen = Set<String>()
        for (index, fieldNode) in fieldNodes.enumerated() {
            let fieldPath = "\(path).fields[\(index)]"
            guard case .object(let fieldPairs) = fieldNode else {
                throw SchemaError(message: "field must be an object", path: fieldPath)
            }
            let fieldMap = dictionary(fieldPairs)
            guard case .string(let fieldName) = fieldMap["name"] ?? .null else {
                throw SchemaError(message: "field requires name", path: fieldPath)
            }
            guard isUnqualifiedName(fieldName) else {
                throw SchemaError(message: "illegal field name \(fieldName)", path: fieldPath)
            }
            if seen.contains(fieldName) {
                throw SchemaError(message: "duplicate field \(fieldName)", path: fieldPath)
            }
            seen.insert(fieldName)
            guard let typeValue = fieldMap["type"] else {
                throw SchemaError(message: "field requires type", path: fieldPath)
            }
            let typeId = try parseSchema(typeValue, enclosing: parsed.space, path: fieldPath + ".type")
            let aliases = try stringList(fieldMap["aliases"], path: fieldPath + ".aliases")
            for alias in aliases where !isUnqualifiedName(alias) {
                throw SchemaError(message: "illegal field alias \(alias)", path: fieldPath)
            }
            let order: Int
            if let orderValue = fieldMap["order"] {
                guard case .string(let text) = orderValue else {
                    throw SchemaError(message: "order must be a string", path: fieldPath)
                }
                switch text {
                case "ascending": order = 0
                case "descending": order = 1
                case "ignore": order = 2
                default:
                    throw SchemaError(message: "illegal order \(text)", path: fieldPath)
                }
            } else {
                order = 0
            }
            var field = FieldDesc(name: fieldName, typeId: typeId)
            field.aliases = aliases
            field.doc = stringField(fieldMap["doc"]) ?? ""
            field.order = order
            if let defaultValue = fieldMap["default"] {
                field.hasDefault = true
                field.defaultJSON = emitJSON(defaultValue)
            }
            fields.append(field)
        }
        pool.nodes[id].fields = fields
        cacheFieldWires(id: id, pool: pool)
        pool.nodes[id].doc = stringField(map["doc"]) ?? ""
        pool.nodes[id].aliases = try nameList(map["aliases"], path: path + ".aliases")
        pool.nodes[id].logicalType = stringField(map["logicalType"]) ?? ""
        pool.nodes[id].attributes = extraAttributes(pairs, known: schemaKeys)
        pool.nodes[id].complete = true
        try registerAliases(pool.nodes[id].aliases, id: id, path: path)
        return id
    }

    func parseEnum(
        _ map: [String: JSONValue],
        pairs: [(String, JSONValue)],
        enclosing: String,
        path: String
    ) throws -> Int {
        guard case .string(let rawName) = map["name"] ?? .null else {
            throw SchemaError(message: "enum requires name", path: path)
        }
        let parsed = try parseFullName(name: rawName, namespace: stringField(map["namespace"]), enclosing: enclosing)
        guard case .array(let symbolNodes) = map["symbols"] ?? .null, !symbolNodes.isEmpty else {
            throw SchemaError(message: "enum requires symbols", path: path)
        }
        var symbols: [String] = []
        var seen = Set<String>()
        for (index, symbolNode) in symbolNodes.enumerated() {
            guard case .string(let symbol) = symbolNode, isUnqualifiedName(symbol) else {
                throw SchemaError(message: "illegal enum symbol", path: "\(path).symbols[\(index)]")
            }
            if seen.contains(symbol) {
                throw SchemaError(message: "duplicate symbol \(symbol)", path: path)
            }
            seen.insert(symbol)
            symbols.append(symbol)
        }
        let id = try claim(parsed, kind: .enumeration, isError: false, path: path)
        pool.nodes[id].symbols = symbols
        pool.nodes[id].doc = stringField(map["doc"]) ?? ""
        pool.nodes[id].aliases = try nameList(map["aliases"], path: path + ".aliases")
        pool.nodes[id].logicalType = stringField(map["logicalType"]) ?? ""
        if let defaultValue = map["default"] {
            guard case .string(let symbol) = defaultValue else {
                throw SchemaError(message: "enum default must be a string", path: path)
            }
            if !seen.contains(symbol) {
                throw SchemaError(message: "enum default \(symbol) is not a symbol", path: path)
            }
            pool.nodes[id].enumDefault = symbol
        }
        pool.nodes[id].attributes = extraAttributes(pairs, known: schemaKeys.union(["symbols", "default"]))
        pool.nodes[id].complete = true
        try registerAliases(pool.nodes[id].aliases, id: id, path: path)
        return id
    }

    func parseFixed(
        _ map: [String: JSONValue],
        pairs: [(String, JSONValue)],
        enclosing: String,
        path: String
    ) throws -> Int {
        guard case .string(let rawName) = map["name"] ?? .null else {
            throw SchemaError(message: "fixed requires name", path: path)
        }
        let parsed = try parseFullName(name: rawName, namespace: stringField(map["namespace"]), enclosing: enclosing)
        guard let sizeValue = map["size"] else {
            throw SchemaError(message: "fixed requires size", path: path)
        }
        guard case .number(let raw) = sizeValue, let size64 = jsonInteger(raw), size64 >= 0, size64 <= Int64(Int.max) else {
            throw SchemaError(message: "fixed size must be a non-negative integer", path: path)
        }
        let id = try claim(parsed, kind: .fixed, isError: false, path: path)
        pool.nodes[id].size = Int(size64)
        pool.nodes[id].doc = stringField(map["doc"]) ?? ""
        pool.nodes[id].aliases = try nameList(map["aliases"], path: path + ".aliases")
        pool.nodes[id].logicalType = stringField(map["logicalType"]) ?? ""
        pool.nodes[id].attributes = extraAttributes(pairs, known: schemaKeys.union(["size"]))
        pool.nodes[id].complete = true
        try registerAliases(pool.nodes[id].aliases, id: id, path: path)
        return id
    }

    func claim(_ parsed: ParsedName, kind: SchemaKind, isError: Bool, path: String) throws -> Int {
        if let id = pool.byName[parsed.full] {
            if pool.nodes[id].complete {
                throw SchemaError(message: "duplicate name \(parsed.full)", path: path)
            }
            pool.nodes[id].kind = kind
            pool.nodes[id].name = parsed.full
            pool.nodes[id].shortName = parsed.short
            pool.nodes[id].namespace = parsed.space
            pool.nodes[id].isError = isError
            return id
        }
        let schema = SchemaNode.make(kind)
        schema.name = parsed.full
        schema.shortName = parsed.short
        schema.namespace = parsed.space
        schema.isError = isError
        let id = pool.add(schema)
        pool.byName[parsed.full] = id
        return id
    }

    func registerAliases(_ aliases: [String], id: Int, path: String) throws {
        for alias in aliases {
            if pool.byName[alias] != nil && pool.byName[alias] != id {
                throw SchemaError(message: "alias \(alias) collides with another name", path: path)
            }
            pool.byName[alias] = id
        }
    }

    func internPrimitive(_ kind: SchemaKind) -> Int {
        if let id = barePrimitives[kind] { return id }
        let schema = SchemaNode.make(kind)
        let name = primitiveToken(kind) ?? ""
        schema.name = name
        schema.shortName = name
        schema.complete = true
        let id = pool.add(schema)
        barePrimitives[kind] = id
        return id
    }

    func checkUnionBranches(_ branches: [Int], path: String) throws {
        var primitiveKinds = Set<SchemaKind>()
        var arrays = 0
        var maps = 0
        var names = Set<String>()
        for id in branches {
            let node = pool.nodes[id]
            switch node.kind {
            case .array:
                arrays += 1
                if arrays > 1 { throw SchemaError(message: "duplicate array in union", path: path) }
            case .map:
                maps += 1
                if maps > 1 { throw SchemaError(message: "duplicate map in union", path: path) }
            case .record, .enumeration, .fixed:
                let name = node.name.isEmpty ? "#\(id)" : node.name
                if names.contains(name) {
                    throw SchemaError(message: "duplicate named type \(name) in union", path: path)
                }
                names.insert(name)
            default:
                if primitiveKinds.contains(node.kind) {
                    throw SchemaError(message: "duplicate \(primitiveToken(node.kind) ?? "type") in union", path: path)
                }
                primitiveKinds.insert(node.kind)
            }
        }
    }

    func validateDefaults() throws {
        for node in pool.nodes where node.kind == .record {
            for field in node.fields where field.hasDefault {
                do {
                    _ = try decodeDefault(field.defaultJSON, pool: pool, typeId: field.typeId)
                } catch {
                    throw SchemaError(
                        message: "default for \(field.name) does not match its type",
                        path: node.name
                    )
                }
            }
        }
    }
}

let schemaKeys: Set<String> = [
    "type", "name", "namespace", "fields", "symbols", "items", "values", "size",
    "default", "aliases", "doc", "logicalType", "order",
]

func dictionary(_ pairs: [(String, JSONValue)]) -> [String: JSONValue] {
    var map: [String: JSONValue] = [:]
    for (key, value) in pairs { map[key] = value }
    return map
}

func stringField(_ value: JSONValue?) -> String? {
    guard let value, case .string(let text) = value else { return nil }
    return text
}

func stringList(_ value: JSONValue?, path: String) throws -> [String] {
    guard let value else { return [] }
    guard case .array(let items) = value else {
        throw SchemaError(message: "expected an array of strings", path: path)
    }
    var out: [String] = []
    for item in items {
        guard case .string(let text) = item else {
            throw SchemaError(message: "expected a string", path: path)
        }
        out.append(text)
    }
    return out
}

func nameList(_ value: JSONValue?, path: String) throws -> [String] {
    let names = try stringList(value, path: path)
    for name in names where !isFullName(name) {
        throw SchemaError(message: "illegal alias \(name)", path: path)
    }
    return names
}

func extraAttributes(_ pairs: [(String, JSONValue)], known: Set<String>) -> [String: String] {
    var extras: [String: String] = [:]
    for (key, value) in pairs where !known.contains(key) {
        extras[key] = emitJSON(value)
    }
    return extras
}

public func shortName(of full: String) -> String {
    guard let dot = full.lastIndex(of: ".") else { return full }
    return String(full[full.index(after: dot)...])
}
