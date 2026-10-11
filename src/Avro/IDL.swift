import Foundation

public protocol ImportResolver {
    func resolve(kind: String, path: String, fromFile: String) throws -> String
}

public struct FileImportResolver: ImportResolver {
    public init() {}

    public func resolve(kind: String, path: String, fromFile: String) throws -> String {
        let full = joinImportPath(path, fromFile: fromFile)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else {
            throw SchemaError(message: "cannot read \(path)", path: fromFile)
        }
        return text
    }
}

public struct MemoryImportResolver: ImportResolver {
    public var files: [String: String]
    public init(files: [String: String]) { self.files = files }

    public func resolve(kind: String, path: String, fromFile: String) throws -> String {
        guard let text = files[path] else {
            throw SchemaError(message: "missing import \(path)", path: fromFile)
        }
        return text
    }
}

func joinImportPath(_ path: String, fromFile: String) -> String {
    if path.hasPrefix("/") { return path }
    guard let slash = fromFile.lastIndex(of: "/") else { return path }
    return String(fromFile[..<slash]) + "/" + path
}

final class ImportGuard {
    var stack: [String] = []
    func push(_ path: String) throws {
        if stack.contains(path) {
            throw SchemaError(message: "import cycle \(path)")
        }
        stack.append(path)
    }
    func pop() { _ = stack.popLast() }
}

public func parseAvdl(
    _ text: String,
    resolver: any ImportResolver = FileImportResolver(),
    fromFile: String = ""
) throws -> SchemaPool {
    let pool = SchemaPool()
    let parser = IDLParser(text: text, pool: pool, resolver: resolver, fromFile: fromFile, imports: ImportGuard())
    try parser.parseFile()
    if pool.root < 0 {
        throw SchemaError(message: "IDL did not declare a named type", path: fromFile)
    }
    pool.originalJSON = emitSchemaJSON(pool)
    try AvscParser(pool: pool).validateDefaults()
    return pool
}

public func parseAvpr(
    _ text: String,
    resolver: any ImportResolver = FileImportResolver(),
    fromFile: String = ""
) throws -> SchemaPool {
    let pool = SchemaPool()
    try parseAvpr(text, into: pool, resolver: resolver, fromFile: fromFile, imports: ImportGuard())
    if pool.root < 0 {
        throw SchemaError(message: "protocol has no types", path: fromFile)
    }
    pool.originalJSON = text.trimmingCharacters(in: .whitespacesAndNewlines)
    try AvscParser(pool: pool).validateDefaults()
    return pool
}

func parseAvpr(
    _ text: String,
    into pool: SchemaPool,
    resolver: any ImportResolver,
    fromFile: String,
    imports: ImportGuard
) throws {
    let json: JSONValue
    do {
        json = try parseJSON(text)
    } catch let error as JSONError {
        throw SchemaError(message: "protocol JSON: \(error.message)", path: fromFile)
    }
    guard case .object(let pairs) = json else {
        throw SchemaError(message: "protocol must be a JSON object", path: fromFile)
    }
    let map = dictionary(pairs)
    guard case .string = map["protocol"] ?? .null else {
        throw SchemaError(message: "protocol object requires protocol name", path: fromFile)
    }
    let namespace = stringField(map["namespace"]) ?? ""
    guard case .array(let types) = map["types"] ?? .null else {
        throw SchemaError(message: "protocol requires types", path: fromFile)
    }
    let schemaParser = AvscParser(pool: pool)
    for (index, item) in types.enumerated() {
        try schemaParser.prescan(item, enclosing: namespace, path: "$.types[\(index)]")
    }
    for (index, item) in types.enumerated() {
        let id = try schemaParser.parseSchema(item, enclosing: namespace, path: "$.types[\(index)]")
        pool.root = id
    }
    _ = resolver
    _ = imports
}

final class IDLParser {
    let pool: SchemaPool
    let resolver: any ImportResolver
    let fromFile: String
    let imports: ImportGuard
    var tokens: [IDLToken] = []
    var index = 0
    var pendingDoc: String?

    init(text: String, pool: SchemaPool, resolver: any ImportResolver, fromFile: String, imports: ImportGuard) {
        self.pool = pool
        self.resolver = resolver
        self.fromFile = fromFile
        self.imports = imports
        var lexer = IDLLexer(text)
        tokens = lexer.tokenize()
    }

    func parseFile() throws {
        try parseDecls(enclosing: "", stop: nil)
        if index < tokens.count {
            throw SchemaError(message: "unexpected token after IDL", path: fromFile)
        }
    }

    func parseDecls(enclosing: String, stop: String?) throws {
        let start = index
        try declareUpcoming(enclosing: enclosing, stop: stop)
        index = start
        while index < tokens.count {
            if let stop, peekSymbol(stop) { return }
            let ann = try parseAnnotations()
            try parseDecl(ann, enclosing: enclosing)
        }
    }

    func parseDecl(_ ann: IDLAnn, enclosing: String) throws {
        guard case .ident(let keyword) = peek() else {
            throw SchemaError(message: "expected declaration", path: fromFile)
        }
        switch keyword {
        case "import":
            _ = try next()
            try parseImport()
        case "protocol":
            _ = try next()
            _ = try expectIdent()
            try expectSymbol("{")
            let ns = ann.namespace ?? enclosing
            try parseDecls(enclosing: ns, stop: "}")
            try expectSymbol("}")
        case "record", "error":
            _ = try next()
            let name = try expectIdent()
            try expectSymbol("{")
            let id = try namedID(name, ann: ann, enclosing: enclosing, kind: .record, isError: keyword == "error")
            let fields = try parseFields(enclosing: pool.nodes[id].namespace)
            try expectSymbol("}")
            pool.nodes[id].fields = fields
            cacheFieldWires(id: id, pool: pool)
            pool.nodes[id].doc = ann.doc ?? ""
            pool.nodes[id].aliases = ann.aliases
            pool.nodes[id].logicalType = ann.logicalType ?? ""
            pool.nodes[id].attributes = ann.attributes
            pool.nodes[id].complete = true
            try registerAliases(ann.aliases, id: id)
            pool.root = id
        case "enum":
            _ = try next()
            let name = try expectIdent()
            try expectSymbol("{")
            let symbols = try parseSymbols()
            try expectSymbol("}")
            let id = try namedID(name, ann: ann, enclosing: enclosing, kind: .enumeration, isError: false)
            pool.nodes[id].symbols = symbols
            if let symbol = ann.enumDefault, !symbols.contains(symbol) {
                throw SchemaError(message: "enum default \(symbol) is not a symbol", path: name)
            }
            pool.nodes[id].enumDefault = ann.enumDefault ?? ""
            pool.nodes[id].doc = ann.doc ?? ""
            pool.nodes[id].aliases = ann.aliases
            pool.nodes[id].complete = true
            try registerAliases(ann.aliases, id: id)
            pool.root = id
        case "fixed":
            _ = try next()
            let name = try expectIdent()
            try expectSymbol("(")
            let sizeText = try expectNumber()
            guard let size = jsonInteger(sizeText), size >= 0, size <= Int64(Int.max) else {
                throw SchemaError(message: "illegal fixed size", path: name)
            }
            try expectSymbol(")")
            try expectSymbol(";")
            let id = try namedID(name, ann: ann, enclosing: enclosing, kind: .fixed, isError: false)
            pool.nodes[id].size = Int(size)
            pool.nodes[id].doc = ann.doc ?? ""
            pool.nodes[id].aliases = ann.aliases
            pool.nodes[id].logicalType = ann.logicalType ?? ""
            pool.nodes[id].attributes = ann.attributes
            pool.nodes[id].complete = true
            try registerAliases(ann.aliases, id: id)
            pool.root = id
        case "message", "oneway":
            try skipStatement()
        default:
            throw SchemaError(message: "unknown declaration \(keyword)", path: fromFile)
        }
    }

    func parseImport() throws {
        guard case .ident(let kind) = peek() else {
            throw SchemaError(message: "import requires a kind", path: fromFile)
        }
        guard kind == "idl" || kind == "schema" || kind == "protocol" else {
            throw SchemaError(message: "unknown import kind \(kind)", path: fromFile)
        }
        _ = try next()
        let path = try expectString()
        try expectSymbol(";")
        let text = try resolver.resolve(kind: kind, path: path, fromFile: fromFile)
        try imports.push(path)
        defer { imports.pop() }
        switch kind {
        case "idl":
            let nested = IDLParser(text: text, pool: pool, resolver: resolver, fromFile: path, imports: imports)
            try nested.parseFile()
        case "schema":
            _ = try parseSchemaText(text, into: pool, enclosing: "")
        case "protocol":
            try parseAvpr(text, into: pool, resolver: resolver, fromFile: path, imports: imports)
        default:
            break
        }
    }

    func parseFields(enclosing: String) throws -> [FieldDesc] {
        var fields: [FieldDesc] = []
        var seen = Set<String>()
        while !peekSymbol("}") {
            let doc = pendingDoc
            pendingDoc = nil
            var ann = try parseAnnotations()
            if ann.doc == nil { ann.doc = doc }
            var typeId = try parseType(enclosing: enclosing)
            if (ann.logicalType != nil || !ann.attributes.isEmpty) && !isNamed(pool.nodes[typeId].kind) {
                let copy = pool.nodes[typeId].copy()
                if let logical = ann.logicalType { copy.logicalType = logical }
                for (key, value) in ann.attributes { copy.attributes[key] = value }
                copy.complete = true
                typeId = pool.add(copy)
            }
            let name = try expectIdent()
            guard isUnqualifiedName(name) else {
                throw SchemaError(message: "illegal field name \(name)", path: name)
            }
            if seen.contains(name) {
                throw SchemaError(message: "duplicate field \(name)", path: name)
            }
            seen.insert(name)
            var field = FieldDesc(name: name, typeId: typeId)
            field.doc = ann.doc ?? ""
            field.aliases = ann.aliases
            field.order = ann.order ?? 0
            if consumeSymbol("=") {
                field.hasDefault = true
                field.defaultJSON = try parseLiteral(typeId: typeId, enclosing: enclosing)
            }
            try expectSymbol(";")
            for alias in field.aliases where !isUnqualifiedName(alias) {
                throw SchemaError(message: "illegal field alias \(alias)", path: name)
            }
            fields.append(field)
        }
        return fields
    }

    func parseSymbols() throws -> [String] {
        var symbols: [String] = []
        var seen = Set<String>()
        if peekSymbol("}") { throw SchemaError(message: "enum requires symbols") }
        while true {
            let symbol = try expectIdent()
            guard isUnqualifiedName(symbol) else {
                throw SchemaError(message: "illegal symbol \(symbol)")
            }
            if seen.contains(symbol) { throw SchemaError(message: "duplicate symbol \(symbol)") }
            seen.insert(symbol)
            symbols.append(symbol)
            if consumeSymbol(",") { if peekSymbol("}") { break }; continue }
            break
        }
        return symbols
    }

    func parseType(enclosing: String) throws -> Int {
        let id = try parsePrimaryType(enclosing: enclosing)
        if consumeSymbol("?") {
            return try makeUnion([internNull(), id])
        }
        return id
    }

    func parsePrimaryType(enclosing: String) throws -> Int {
        guard case .ident(let name) = peek() else {
            throw SchemaError(message: "expected type", path: fromFile)
        }
        switch name {
        case "array":
            _ = try next()
            try expectSymbol("<")
            let item = try parseType(enclosing: enclosing)
            try expectSymbol(">")
            let node = SchemaNode.make(.array)
            node.itemId = item
            node.complete = true
            return pool.add(node)
        case "map":
            _ = try next()
            try expectSymbol("<")
            let value = try parseType(enclosing: enclosing)
            try expectSymbol(">")
            let node = SchemaNode.make(.map)
            node.valueId = value
            node.complete = true
            return pool.add(node)
        case "union":
            _ = try next()
            try expectSymbol("{")
            var branches: [Int] = []
            while !peekSymbol("}") {
                branches.append(try parseType(enclosing: enclosing))
                if !consumeSymbol(",") { break }
            }
            try expectSymbol("}")
            if branches.isEmpty { throw SchemaError(message: "empty union") }
            return try makeUnion(branches)
        default:
            let dotted = try parseDottedName()
            if let kind = kindOfPrimitive(dotted), !dotted.contains(".") {
                return internKind(kind)
            }
            let parsed = try parseFullName(name: dotted, namespace: nil, enclosing: enclosing)
            guard let id = pool.byName[parsed.full] else {
                throw SchemaError(message: "unknown name \(parsed.full)", path: fromFile)
            }
            return id
        }
    }

    func parseLiteral(typeId: Int, enclosing: String) throws -> String {
        let node = pool.nodes[typeId]
        if node.kind == .union {
            guard let first = node.branchIds.first else { throw SchemaError(message: "empty union default") }
            return try parseLiteral(typeId: first, enclosing: enclosing)
        }
        switch node.kind {
        case .null:
            try expectIdent("null")
            return "null"
        case .boolean:
            let word = try expectIdent()
            guard word == "true" || word == "false" else { throw SchemaError(message: "expected boolean") }
            return word
        case .int, .long, .float, .double:
            if consumeSymbol("-") {
                let number = try expectNumber()
                return "-" + number
            }
            return try expectNumber()
        case .string, .bytes:
            return emitJSON(.string(try expectString()))
        case .enumeration:
            let symbol = try expectIdent()
            if !node.symbols.isEmpty && !node.symbols.contains(symbol) {
                throw SchemaError(message: "\(symbol) is not a symbol of \(node.name)")
            }
            return emitJSON(.string(symbol))
        case .fixed:
            let text = try expectString()
            let bytes = try latin1Bytes(text)
            guard bytes.count == node.size else { throw SchemaError(message: "fixed literal size") }
            return emitJSON(.string(text))
        case .array:
            try expectSymbol("[")
            var items: [String] = []
            while !peekSymbol("]") {
                items.append(try parseLiteral(typeId: node.itemId, enclosing: enclosing))
                if !consumeSymbol(",") { break }
            }
            try expectSymbol("]")
            return "[" + items.joined(separator: ",") + "]"
        case .map:
            try expectSymbol("{")
            var parts: [String] = []
            while !peekSymbol("}") {
                let key = try expectString()
                try expectSymbol(":")
                let value = try parseLiteral(typeId: node.valueId, enclosing: enclosing)
                parts.append(emitJSON(.string(key)) + ":" + value)
                if !consumeSymbol(",") { break }
            }
            try expectSymbol("}")
            return "{" + parts.joined(separator: ",") + "}"
        case .record:
            try expectSymbol("{")
            var present: [String: String] = [:]
            while !peekSymbol("}") {
                let fieldName = try expectIdent()
                try expectSymbol("=")
                guard let field = node.fields.first(where: { $0.name == fieldName }) else {
                    throw SchemaError(message: "unknown field \(fieldName) in default")
                }
                present[fieldName] = try parseLiteral(typeId: field.typeId, enclosing: enclosing)
                if !consumeSymbol(",") { break }
            }
            try expectSymbol("}")
            var parts: [String] = []
            for field in node.fields {
                if let value = present[field.name] {
                    parts.append(emitJSON(.string(field.name)) + ":" + value)
                }
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .union:
            throw SchemaError(message: "nested union literal")
        }
    }

    func declareUpcoming(enclosing: String, stop: String?) throws {
        let savedDoc = pendingDoc
        while index < tokens.count {
            if let stop, peekSymbol(stop) { break }
            let ann = try parseAnnotations()
            guard case .ident(let keyword) = peek() else { break }
            switch keyword {
            case "protocol":
                _ = try next()
                _ = try expectIdent()
                try expectSymbol("{")
                try skipBalanced()
            case "record", "error", "enum", "fixed":
                _ = try next()
                let name = try expectIdent()
                let parsed = try parseFullName(name: name, namespace: ann.namespace, enclosing: enclosing)
                if pool.byName[parsed.full] == nil {
                    let node = SchemaNode.make(keyword == "enum" ? .enumeration : (keyword == "fixed" ? .fixed : .record))
                    node.name = parsed.full
                    node.shortName = parsed.short
                    node.namespace = parsed.space
                    node.isError = keyword == "error"
                    let id = pool.add(node)
                    pool.byName[parsed.full] = id
                }
                if keyword == "fixed" {
                    try skipStatement()
                } else {
                    try expectSymbol("{")
                    try skipBalanced()
                }
            case "import":
                try skipStatement()
            case "message", "oneway":
                try skipStatement()
            default:
                try skipStatement()
            }
        }
        pendingDoc = savedDoc
    }

    func namedID(_ rawName: String, ann: IDLAnn, enclosing: String, kind: SchemaKind, isError: Bool) throws -> Int {
        let namespace = ann.namespace
        let parsed = try parseFullName(name: rawName, namespace: namespace, enclosing: enclosing)
        if let id = pool.byName[parsed.full] {
            if pool.nodes[id].complete {
                throw SchemaError(message: "duplicate name \(parsed.full)")
            }
            pool.nodes[id].kind = kind
            pool.nodes[id].name = parsed.full
            pool.nodes[id].shortName = parsed.short
            pool.nodes[id].namespace = parsed.space
            pool.nodes[id].isError = isError
            return id
        }
        let node = SchemaNode.make(kind)
        node.name = parsed.full
        node.shortName = parsed.short
        node.namespace = parsed.space
        node.isError = isError
        let id = pool.add(node)
        pool.byName[parsed.full] = id
        return id
    }

    func registerAliases(_ aliases: [String], id: Int) throws {
        for alias in aliases {
            if let existing = pool.byName[alias], existing != id {
                throw SchemaError(message: "alias \(alias) collides")
            }
            pool.byName[alias] = id
        }
    }

    func makeUnion(_ branches: [Int]) throws -> Int {
        for id in branches where pool.nodes[id].kind == .union {
            throw SchemaError(message: "unions cannot contain other unions")
        }
        try AvscParser(pool: pool).checkUnionBranches(branches, path: "")
        let node = SchemaNode.make(.union)
        node.branchIds = branches
        node.complete = true
        return pool.add(node)
    }

    func internNull() -> Int { internKind(.null) }

    func internKind(_ kind: SchemaKind) -> Int {
        for (id, node) in pool.nodes.enumerated() where node.kind == kind && node.logicalType.isEmpty && node.complete && !isNamed(kind) && node.attributes.isEmpty {
            if kind == .array || kind == .map || kind == .union || kind == .record { continue }
            if node.name == (primitiveToken(kind) ?? "") { return id }
        }
        let node = SchemaNode.make(kind)
        node.name = primitiveToken(kind) ?? ""
        node.shortName = node.name
        node.complete = true
        return pool.add(node)
    }

    func parseAnnotations() throws -> IDLAnn {
        var ann = IDLAnn()
        while peekSymbol("@") {
            _ = try next()
            let name = try expectIdent()
            var args: [IDLArg] = []
            if consumeSymbol("(") {
                if !peekSymbol(")") {
                    while true {
                        args.append(try parseArg())
                        if !consumeSymbol(",") { break }
                    }
                }
                try expectSymbol(")")
            }
            switch name {
            case "namespace":
                guard case .string(let value) = args.first else { throw SchemaError(message: "@namespace needs a string") }
                ann.namespace = value
            case "aliases":
                guard case .list(let values) = args.first else { throw SchemaError(message: "@aliases needs an array") }
                ann.aliases = try values.map { value in
                    guard case .string(let text) = value else { throw SchemaError(message: "alias must be a string") }
                    guard isFullName(text) else { throw SchemaError(message: "illegal alias \(text)") }
                    return text
                }
            case "order":
                guard case .string(let value) = args.first else { throw SchemaError(message: "@order needs a string") }
                switch value {
                case "ascending": ann.order = 0
                case "descending": ann.order = 1
                case "ignore": ann.order = 2
                default: throw SchemaError(message: "illegal order \(value)")
                }
            case "logicalType":
                guard case .string(let value) = args.first else { throw SchemaError(message: "@logicalType needs a string") }
                ann.logicalType = value
            case "precision", "scale":
                let raw: String
                switch args.first {
                case .number(let number): raw = number
                case .string(let text): raw = text
                default: throw SchemaError(message: "@\(name) needs a number")
                }
                ann.attributes[name] = raw
            default:
                if let arg = args.first {
                    ann.attributes[name] = arg.jsonText
                } else {
                    ann.attributes[name] = "true"
                }
            }
        }
        if ann.doc == nil { ann.doc = pendingDoc; pendingDoc = nil }
        return ann
    }

    func parseArg() throws -> IDLArg {
        if consumeSymbol("[") {
            var items: [IDLArg] = []
            if !peekSymbol("]") {
                while true {
                    items.append(try parseArg())
                    if !consumeSymbol(",") { break }
                }
            }
            try expectSymbol("]")
            return .list(items)
        }
        switch peek() {
        case .string(let value):
            _ = try next()
            return .string(value)
        case .number(let value):
            _ = try next()
            return .number(value)
        case .ident(let value):
            _ = try next()
            return .string(value)
        case .symbol("-"):
            _ = try next()
            let number = try expectNumber()
            return .number("-" + number)
        default:
            throw SchemaError(message: "bad annotation argument")
        }
    }

    func parseDottedName() throws -> String {
        var parts = [try expectIdent()]
        while consumeSymbol(".") {
            parts.append(try expectIdent())
        }
        return parts.joined(separator: ".")
    }

    func skipBalanced() throws {
        var depth = 1
        while index < tokens.count && depth > 0 {
            if case .symbol(let symbol) = tokens[index] {
                if symbol == "{" { depth += 1 }
                if symbol == "}" { depth -= 1 }
            }
            index += 1
        }
        if depth != 0 { throw SchemaError(message: "unbalanced braces") }
    }

    func skipStatement() throws {
        var depth = 0
        while index < tokens.count {
            if case .symbol(let symbol) = tokens[index] {
                if symbol == "{" || symbol == "(" || symbol == "[" { depth += 1 }
                if symbol == "}" || symbol == ")" || symbol == "]" { depth -= 1 }
                index += 1
                if symbol == ";" && depth <= 0 { return }
                continue
            }
            index += 1
        }
    }

    func peek() -> IDLToken {
        while index < tokens.count {
            if case .doc(let text) = tokens[index] {
                pendingDoc = text
                index += 1
                continue
            }
            return tokens[index]
        }
        return .end
    }

    func peekSymbol(_ symbol: String) -> Bool {
        if case .symbol(let found) = peek() { return String(found) == symbol }
        return false
    }

    func next() throws -> IDLToken {
        let token = peek()
        if case .end = token {
            throw SchemaError(message: "unexpected end of IDL", path: fromFile)
        }
        index += 1
        return token
    }

    @discardableResult
    func expectIdent(_ expected: String? = nil) throws -> String {
        let token = try next()
        guard case .ident(let value) = token else { throw SchemaError(message: "expected identifier") }
        if let expected, value != expected { throw SchemaError(message: "expected \(expected)") }
        return value
    }

    func expectString() throws -> String {
        let token = try next()
        guard case .string(let value) = token else { throw SchemaError(message: "expected string") }
        return value
    }

    func expectNumber() throws -> String {
        let token = try next()
        guard case .number(let value) = token else { throw SchemaError(message: "expected number") }
        return value
    }

    func expectSymbol(_ symbol: String) throws {
        let token = try next()
        guard case .symbol(let found) = token, String(found) == symbol else {
            throw SchemaError(message: "expected \(symbol)")
        }
    }

    func consumeSymbol(_ symbol: String) -> Bool {
        if peekSymbol(symbol) {
            index += 1
            return true
        }
        return false
    }
}

struct IDLAnn {
    var namespace: String?
    var aliases: [String] = []
    var order: Int?
    var logicalType: String?
    var enumDefault: String?
    var doc: String?
    var attributes: [String: String] = [:]
}

enum IDLArg {
    case string(String)
    case number(String)
    case list([IDLArg])

    var jsonText: String {
        switch self {
        case .string(let value): return emitJSON(.string(value))
        case .number(let value): return value
        case .list(let items): return "[" + items.map(\.jsonText).joined(separator: ",") + "]"
        }
    }
}

enum IDLToken {
    case ident(String)
    case string(String)
    case number(String)
    case symbol(Character)
    case doc(String)
    case end
}

struct IDLLexer {
    let bytes: [UInt8]
    var index = 0
    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func tokenize() -> [IDLToken] {
        var tokens: [IDLToken] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
                index += 1
                continue
            }
            if byte == 0x2f && index + 1 < bytes.count && bytes[index + 1] == 0x2f {
                index += 2
                while index < bytes.count && bytes[index] != 0x0a { index += 1 }
                continue
            }
            if byte == 0x2f && index + 1 < bytes.count && bytes[index + 1] == 0x2a {
                let doc = index + 2 < bytes.count && bytes[index + 2] == 0x2a && !(index + 3 < bytes.count && bytes[index + 3] == 0x2f)
                index += 2
                let start = index
                while index + 1 < bytes.count && !(bytes[index] == 0x2a && bytes[index + 1] == 0x2f) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                if index + 1 < bytes.count { index += 2 } else { index = bytes.count }
                if doc { tokens.append(.doc(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
                continue
            }
            if byte == 0x22 {
                tokens.append(.string(readString()))
                continue
            }
            if isIdentStart(byte) {
                let start = index
                index += 1
                while index < bytes.count && isIdentCont(bytes[index]) { index += 1 }
                tokens.append(.ident(String(decoding: bytes[start..<index], as: UTF8.self)))
                continue
            }
            if isDigit(byte) || (byte == 0x2d && index + 1 < bytes.count && isDigit(bytes[index + 1])) {
                tokens.append(.number(readNumber()))
                continue
            }
            tokens.append(.symbol(Character(UnicodeScalar(byte))))
            index += 1
        }
        return tokens
    }

    mutating func readString() -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 { break }
            if byte == 0x5c && index < bytes.count {
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case 0x6e: scalars.append(UnicodeScalar(0x0a))
                case 0x72: scalars.append(UnicodeScalar(0x0d))
                case 0x74: scalars.append(UnicodeScalar(0x09))
                case 0x22: scalars.append(UnicodeScalar(0x22))
                case 0x5c: scalars.append(UnicodeScalar(0x5c))
                case 0x2f: scalars.append(UnicodeScalar(0x2f))
                default: scalars.append(UnicodeScalar(escaped))
                }
                continue
            }
            scalars.append(UnicodeScalar(byte))
        }
        return String(scalars)
    }

    mutating func readNumber() -> String {
        let start = index
        if bytes[index] == 0x2d { index += 1 }
        while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        if index < bytes.count && bytes[index] == 0x2e {
            index += 1
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2b || bytes[index] == 0x2d) { index += 1 }
            while index < bytes.count && isDigit(bytes[index]) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

func isIdentStart(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x5f
}

func isIdentCont(_ byte: UInt8) -> Bool {
    isIdentStart(byte) || isDigit(byte)
}

func parseSchemaText(_ text: String, into pool: SchemaPool, enclosing: String) throws -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let json: JSONValue
    do { json = try parseJSON(trimmed) } catch let error as JSONError {
        throw SchemaError(message: error.message, path: "offset \(error.offset)")
    }
    let parser = AvscParser(pool: pool)
    try parser.prescan(json, enclosing: enclosing, path: "$")
    let root = try parser.parseSchema(json, enclosing: enclosing, path: "$")
    try parser.validateDefaults()
    pool.root = root
    if pool.originalJSON.isEmpty { pool.originalJSON = trimmed }
    return root
}
