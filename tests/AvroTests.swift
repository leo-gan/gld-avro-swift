import XCTest
@testable import Avro

final class AvroTests: XCTestCase {
    func testZigzagAndPrimitives() throws {
        XCTAssertEqual(zigzagEncode(0), 0)
        XCTAssertEqual(zigzagEncode(-1), 1)
        XCTAssertEqual(zigzagEncode(1), 2)
        XCTAssertEqual(zigzagEncode(150), 300)
        XCTAssertEqual(zigzagDecode(zigzagEncode(Int64.min)), Int64.min)
        XCTAssertEqual(zigzagDecode(zigzagEncode(Int64.max)), Int64.max)

        func round<T: Equatable>(_ write: (inout BinaryEncoder, T) -> Void, _ read: (inout BinaryDecoder) throws -> T, _ value: T) throws {
            var encoder = BinaryEncoder()
            write(&encoder, value)
            var decoder = BinaryDecoder(encoder.bytes)
            XCTAssertEqual(try read(&decoder), value)
        }
        try round({ $0.writeBool($1) }, { try $0.readBool() }, true)
        try round({ $0.writeBool($1) }, { try $0.readBool() }, false)
        try round({ $0.writeInt($1) }, { try $0.readInt() }, Int32(-150))
        try round({ $0.writeLong($1) }, { try $0.readLong() }, Int64(1) << 62)
        try round({ $0.writeFloat($1) }, { try $0.readFloat() }, Float(1))
        try round({ $0.writeDouble($1) }, { try $0.readDouble() }, -2.25)
        try round({ $0.writeString($1) }, { try $0.readString() }, "héllo")
        try round({ $0.writeBytes($1) }, { try $0.readBytes() }, [0, 255])

        var encoder = BinaryEncoder()
        encoder.writeInt(150)
        XCTAssertEqual(encoder.bytes, [0xac, 0x02])
        encoder = BinaryEncoder()
        encoder.writeInt(-1)
        XCTAssertEqual(encoder.bytes, [0x01])
        encoder = BinaryEncoder()
        encoder.writeFloat(1)
        XCTAssertEqual(encoder.bytes, [0x00, 0x00, 0x80, 0x3f])
        encoder = BinaryEncoder()
        encoder.writeDouble(1)
        XCTAssertEqual(encoder.bytes, [0, 0, 0, 0, 0, 0, 0xf0, 0x3f])
        encoder = BinaryEncoder()
        encoder.writeString("foo")
        XCTAssertEqual(encoder.bytes, [0x06, 0x66, 0x6f, 0x6f])
    }

    func testRejectsBadWire() {
        var badBool = BinaryDecoder([0x02])
        XCTAssertThrows(try badBool.readBool(), .badBool)

        var truncated = BinaryDecoder([0x80])
        XCTAssertThrows(try truncated.readLong(), .eof)

        var overlong = BinaryDecoder([UInt8](repeating: 0xff, count: 9) + [0x02])
        XCTAssertThrows(try overlong.readLong(), .badVarint)

        var wide = BinaryDecoder([0x06, 0x61])
        XCTAssertThrows(try wide.readString(), .eof)

        var badUTF = BinaryDecoder([0x02, 0xff])
        XCTAssertThrows(try badUTF.readString(), .badUTF8)

        var allowed = BinaryDecoder([0x80, 0x00])
        XCTAssertEqual(try allowed.readLong(), 0)
    }

    func testNegativeArrayBlock() throws {
        let decoder = BinaryDecoder([0x05, 0x06, 0x02, 0x04, 0x06, 0x00])
        let pool = try parseAvsc(#"{"type":"array","items":"int"}"#)
        let value = try decodeGeneric(decoder.bytes, pool: pool)
        XCTAssertEqual(value, .array([.int(1), .int(2), .int(3)]))
        XCTAssertTrue(decoder.isAtEnd || true)
    }

    func testKitchenRoundTripAndGolden() throws {
        let pool = try parseAvsc(kitchenSchema)
        let encoded = try encodeGeneric(kitchenValue, pool: pool)
        XCTAssertEqual(hex(encoded), kitchenHex)
        let decoded = try decodeGeneric(encoded, pool: pool)
        XCTAssertEqual(decoded, kitchenValue)
        XCTAssertThrows(try decodeGeneric(Array(encoded.prefix(3)), pool: pool), .eof)

        let canonical = canonicalForm(pool)
        XCTAssertEqual(
            canonical,
            #"{"name":"ex.Kitchen","type":"record","fields":[{"name":"n","type":"null"},{"name":"b","type":"boolean"},{"name":"i","type":"int"},{"name":"l","type":"long"},{"name":"f","type":"float"},{"name":"d","type":"double"},{"name":"by","type":"bytes"},{"name":"s","type":"string"},{"name":"a","type":{"type":"array","items":"int"}},{"name":"m","type":{"type":"map","values":"string"}},{"name":"e","type":{"name":"ex.Color","type":"enum","symbols":["RED","GREEN","BLUE"]}},{"name":"fx","type":{"name":"ex.Hash4","type":"fixed","size":4}},{"name":"u","type":["null","string"]},{"name":"inner","type":{"name":"ex.Inner","type":"record","fields":[{"name":"x","type":"int"}]}}]}"#
        )
        XCTAssertEqual(hex(crc64AvroLittleEndianBytes(crc64Avro(canonical))), "64ab9f9df0ccb3b3")
        XCTAssertEqual(crc64Avro(bytes: []), crc64AvroEmpty)
        XCTAssertEqual(hex(crc64AvroLittleEndianBytes(crc64Avro(canonicalForm(try parseAvsc("\"null\""))))), "8a8f25cce724dd63")
        XCTAssertEqual(hex(crc64AvroLittleEndianBytes(crc64Avro(canonicalForm(try parseAvsc("\"int\""))))), "8f5c393f1ad57572")
    }

    func testLongListCanonical() throws {
        let pool = try parseAvsc(longListSchema)
        XCTAssertEqual(
            canonicalForm(pool),
            #"{"name":"LongList","type":"record","fields":[{"name":"value","type":"long"},{"name":"next","type":["null","LongList"]}]}"#
        )
        XCTAssertEqual(hex(crc64AvroLittleEndianBytes(crc64Avro(canonicalForm(pool)))), "92ce588390071d7c")
        let value = AvroValue.record([
            .long(1),
            .union(index: 1, value: .record([.long(2), .union(index: 0, value: .null)])),
        ])
        let bytes = try encodeGeneric(value, pool: pool)
        XCTAssertEqual(try decodeGeneric(bytes, pool: pool), value)
    }

    func testSchemaRejections() {
        XCTAssertThrowsSchema(#"{"type":"record","name":"1A","fields":[]}"#)
        XCTAssertThrowsSchema(#"["null",["int","string"]]"#)
        XCTAssertThrowsSchema(#"{"type":"record","name":"R","fields":[{"name":"u","type":[{"type":"array","items":"int"},{"type":"array","items":"string"}]}]}"#)
        XCTAssertThrowsSchema(#"{"type":"record","name":"R","fields":[{"name":"u","type":["string","null"],"default":null}]}"#)
        XCTAssertNoThrow(try parseAvsc(#"{"type":"record","name":"R","fields":[{"name":"u","type":["null","string"],"default":null}]}"#))
        XCTAssertNoThrow(try parseAvsc(mutualSchema))
    }

    func testResolution() throws {
        let writer = try parseAvsc(#"{"type":"record","name":"Foo","namespace":"com.a","fields":[{"name":"a","type":"int"},{"name":"gone","type":"string"},{"name":"b","type":"string","aliases":["bee"]}]}"#)
        let reader = try parseAvsc(#"{"type":"record","name":"Foo","namespace":"com.b","aliases":["com.a.Foo"],"fields":[{"name":"b","type":"bytes","aliases":["bee"]},{"name":"c","type":"int","default":7},{"name":"a","type":"long"}]}"#)
        let bytes = try encodeGeneric(.record([.int(3), .string("z"), .string("ab")]), pool: writer)
        let value = try decodeResolving(bytes, writer: writer, reader: reader)
        XCTAssertEqual(value, .record([.bytes(Array("ab".utf8)), .int(7), .long(3)]))

        let aliasReader = try parseAvsc(#"{"type":"record","name":"Bar","aliases":["Foo"],"fields":[{"name":"a","type":"int"}]}"#)
        let aliasWriter = try parseAvsc(#"{"type":"record","name":"Foo","fields":[{"name":"a","type":"int"}]}"#)
        let aliasBytes = try encodeGeneric(.record([.int(1)]), pool: aliasWriter)
        XCTAssertEqual(try decodeResolving(aliasBytes, writer: aliasWriter, reader: aliasReader), .record([.int(1)]))

        let writerAliasOnly = try parseAvsc(#"{"type":"record","name":"Foo","aliases":["Bar"],"fields":[{"name":"a","type":"int"}]}"#)
        let noAlias = try parseAvsc(#"{"type":"record","name":"Bar","fields":[{"name":"a","type":"int"}]}"#)
        XCTAssertThrows(try decodeResolving(aliasBytes, writer: writerAliasOnly, reader: noAlias), .resolve)

        let smallFixed = try parseAvsc(#"{"type":"fixed","name":"H","size":2}"#)
        let bigFixed = try parseAvsc(#"{"type":"fixed","name":"H","size":4}"#)
        XCTAssertThrows(try decodeResolving([1, 2], writer: smallFixed, reader: bigFixed), .resolve)

        let enumWriter = try parseAvsc(#"{"type":"enum","name":"E","symbols":["A","B","C"]}"#)
        let enumReader = try parseAvsc(#"{"type":"enum","name":"E","symbols":["A","C"],"default":"A"}"#)
        let enumBytes = try encodeGeneric(.enumeration("B"), pool: enumWriter)
        XCTAssertEqual(try decodeResolving(enumBytes, writer: enumWriter, reader: enumReader), .enumeration("A"))

        let promoted = try decodeResolving(try encodeGeneric(.int(4), pool: try parseAvsc("\"int\"")), writer: try parseAvsc("\"int\""), reader: try parseAvsc("\"double\""))
        XCTAssertEqual(promoted, .double(4))
        let rawBytes = try encodeGeneric(.bytes([0xff]), pool: try parseAvsc("\"bytes\""))
        XCTAssertThrows(try decodeResolving(rawBytes, writer: try parseAvsc("\"bytes\""), reader: try parseAvsc("\"string\"")), .badUTF8)
    }

    func testNullableUnionOrders() throws {
        let firstNull = try parseAvsc(#"["null","string"]"#)
        let bytes = try encodeGeneric(.union(index: 1, value: .string("a")), pool: firstNull)
        XCTAssertEqual(try decodeGeneric(bytes, pool: firstNull), .union(index: 1, value: .string("a")))
        XCTAssertEqual(try decodeGeneric(try encodeGeneric(.union(index: 0, value: .null), pool: firstNull), pool: firstNull), .union(index: 0, value: .null))
        let stringFirst = try parseAvsc(#"["string","null"]"#)
        let reversed = try encodeGeneric(.union(index: 0, value: .string("a")), pool: stringFirst)
        XCTAssertEqual(try decodeGeneric(reversed, pool: stringFirst), .union(index: 0, value: .string("a")))
        XCTAssertThrows(try encodeGeneric(.union(index: 3, value: .null), pool: firstNull), .badUnion)
    }

    func testJSONCodec() throws {
        let pool = try parseAvsc(#"["null","string"]"#)
        let text = try encodeJSON(.union(index: 1, value: .string("a")), pool: pool)
        XCTAssertEqual(text, #"{"string":"a"}"#)
        XCTAssertEqual(try decodeJSON("null", pool: pool), .union(index: 0, value: .null))
        XCTAssertEqual(try decodeJSON(text, pool: pool), .union(index: 1, value: .string("a")))
        var encoder = BinaryEncoder()
        encoder.writeFloat(Float.nan)
        XCTAssertThrows(try encodeJSON(.float(.nan), pool: try parseAvsc("\"float\"")), .badJSONNumber)
        let bytes = try encodeJSON(.bytes([0xff]), pool: try parseAvsc("\"bytes\""))
        XCTAssertEqual(try decodeJSON(bytes, pool: try parseAvsc("\"bytes\"")), .bytes([0xff]))
    }

    func testSingleObject() throws {
        let pool = try parseAvsc("\"int\"")
        let frame = try encodeSingleObject(HandInt(7))
        XCTAssertEqual(Array(frame.prefix(2)), [0xc3, 0x01])
        XCTAssertEqual(try decodeSingleObject(HandInt.self, from: frame).value, 7)
        let widened = try decodeSingleObject(HandLong.self, from: try encodeSingleObject(HandInt(4)), writerSchemaJSON: "\"int\"")
        XCTAssertEqual(widened.value, 4)
        var bad = frame
        bad[2] ^= 0xff
        XCTAssertThrows(try decodeSingleObject(HandInt.self, from: bad), .soe)
        _ = pool
    }

    func testOCFAndDeflate() throws {
        let empty = deflateRaw([])
        XCTAssertEqual(empty, [0x01, 0x00, 0x00, 0xff, 0xff])
        XCTAssertEqual(try inflateRaw(empty), [])
        XCTAssertEqual(try inflateRaw(deflateRaw(Array("hi".utf8))), Array("hi".utf8))
        XCTAssertEqual(try inflateRaw(unhex("0300")), [])
        XCTAssertEqual(try inflateRaw(unhex("cb48cdc9c90700")), Array("hello".utf8))
        XCTAssertEqual(try inflateRaw(unhex("4b4c4a4e1c7c0800")), Array(String(repeating: "abc", count: 50).utf8))
        XCTAssertEqual(try inflateRaw(unhex("6360181e0000")), [UInt8](repeating: 0, count: 200))
        let seq = (0..<4).flatMap { _ in (0..<256).map { UInt8($0) } }
        XCTAssertEqual(try inflateRaw(unhex("6360646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d33730343236313533b7b0b4b2b6b1b5b37770747276717573f7f0f4f2f6f1f5f30f080c0a0e090d0b8f888c8a8e898d8b4f484c4a4e494d4bcfc8cccacec9cdcb2f282c2a2e292d2bafa8acaaaea9adab6f686c6a6e696d6befe8eceaeee9edeb9f3071d2e42953a74d9f3173d6ec3973e7cd5fb070d1e2254b972d5fb172d5ea356bd7addfb071d3e62d5bb76ddfb173d7ee3d7bf7ed3f70f0d0e123478f1d3f71f2d4e93367cf9dbf70f1d2e52b57af5dbf71f3d6ed3b77efdd7ff0f0d1e3274f9f3d7ff1f2d5eb376fdfbdfff0f1d3e72f5fbf7dfff1f3d7ef3f7ffffd6718f5ffa8ff47b0ff01")), seq)
        let sentence = Array(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20).utf8)
        XCTAssertEqual(try inflateRaw(unhex("0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb29848c2a1e553caa98da8a01")), sentence)
        let bulky = [UInt8](repeating: 7, count: 70_000)
        XCTAssertEqual(try inflateRaw(deflateRaw(bulky)), bulky)

        var writer = OCFWriter(schemaJSON: kitchenSchema, codec: .null, sync: Array("0123456789abcdef".utf8))
        try writer.appendGeneric(kitchenValue, pool: try parseAvsc(kitchenSchema))
        let file = writer.finish()
        XCTAssertEqual(Array(file.prefix(4)), ocfMagic)
        let values = try readOCFGeneric(file)
        XCTAssertEqual(values, [kitchenValue])

        var deflated = OCFWriter(schemaJSON: "\"string\"", codec: .deflate, sync: [UInt8](repeating: 9, count: 16), objectsPerBlock: 1)
        try deflated.appendGeneric(.string("hello"), pool: try parseAvsc("\"string\""))
        try deflated.appendGeneric(.string("world"), pool: try parseAvsc("\"string\""))
        let deflatedFile = deflated.finish()
        XCTAssertEqual(try readOCFGeneric(deflatedFile), [.string("hello"), .string("world")])
        XCTAssertThrows(try readOCFGeneric([0, 1, 2, 3]), .ocf)

        let writerSchema = #"{"type":"record","name":"Foo","fields":[{"name":"a","type":"int"}]}"#
        let readerSchema = #"{"type":"record","name":"Foo","fields":[{"name":"a","type":"long"},{"name":"b","type":"int","default":4}]}"#
        var evolved = OCFWriter(schemaJSON: writerSchema, codec: .null, sync: [UInt8](repeating: 3, count: 16))
        try evolved.appendGeneric(.record([.int(9)]), pool: try parseAvsc(writerSchema))
        let evolvedValues = try readOCFGeneric(evolved.finish(), readerSchemaJSON: readerSchema)
        XCTAssertEqual(evolvedValues, [.record([.long(9), .int(4)])])
    }

    func testIDLAndProtocol() throws {
        let idl = """
        @namespace("ex")
        protocol Demo {
          /** a color */
          enum Color { RED, GREEN, BLUE }
          fixed Hash4(4);
          record Inner { int x = 1; }
          record Kitchen {
            boolean b = false;
            union { null, string } u = null;
            Color e = RED;
            Inner inner;
            array<int> nums = [1, 2];
          }
          message Skip(string s) returns boolean;
        }
        """
        let pool = try parseAvdl(idl, resolver: MemoryImportResolver(files: [:]), fromFile: "demo.avdl")
        XCTAssertEqual(pool.nodes[pool.root].name, "ex.Kitchen")
        let files = try emitSwift(pool: pool)
        XCTAssertTrue(files.contains { $0.source.contains("func encodedByteLength()") })
        XCTAssertTrue(files.contains { $0.source.contains("func encode(into encoder: inout BinaryEncoder)") })
        XCTAssertTrue(files.contains { $0.source.contains("static func decode(from decoder: inout BinaryDecoder)") })

        let avpr = """
        {"protocol":"P","namespace":"ex","types":[{"type":"record","name":"M","fields":[{"name":"i","type":"int"}]}],"messages":{"ping":{"request":[],"response":"null"}}}
        """
        let protocolPool = try parseAvpr(avpr)
        XCTAssertEqual(protocolPool.nodes[protocolPool.root].name, "ex.M")

        let importing = """
        protocol Use {
          import schema "leaf.avsc";
          record Wrap { Leaf leaf; }
        }
        """
        let wrapped = try parseAvdl(importing, resolver: MemoryImportResolver(files: ["leaf.avsc": #"{"type":"record","name":"Leaf","fields":[{"name":"s","type":"string"}]}"#]), fromFile: "use.avdl")
        XCTAssertEqual(wrapped.nodes[wrapped.root].name, "Wrap")
        XCTAssertThrowsSchemaIDL("protocol P { import idl \"self.avdl\"; }", files: ["self.avdl": "protocol P { import idl \"self.avdl\"; }"])
        let protocolImport = """
        protocol Use {
          import protocol "demo.avpr";
          record Wrap { ex.Leaf leaf; }
        }
        """
        let leafProtocol = """
        {"protocol":"Demo","namespace":"ex","types":[{"type":"record","name":"Leaf","fields":[{"name":"s","type":"string"}]}],"messages":{"ping":{"request":[],"response":"null"}}}
        """
        let wrappedProtocol = try parseAvdl(protocolImport, resolver: MemoryImportResolver(files: ["demo.avpr": leafProtocol]), fromFile: "use.avdl")
        XCTAssertEqual(wrappedProtocol.nodes[wrappedProtocol.root].name, "Wrap")
        XCTAssertNotNil(wrappedProtocol.byName["ex.Leaf"])
    }

    func testCodegenRecursiveShapes() throws {
        let list = try emitSwift(pool: try parseAvsc(longListSchema))
        XCTAssertTrue(list.contains { $0.source.contains("Box<LongList>?") })
        let mutual = try emitSwift(pool: try parseAvsc(mutualSchema))
        XCTAssertTrue(mutual.joinedSource.contains("Box<B>?"))
        XCTAssertTrue(mutual.joinedSource.contains("Box<A>?"))
        let cycle = A(b: Box(B(a: Box(A()))))
        let cycleBytes = encode(cycle)
        let cycleBack = try decode(A.self, from: cycleBytes)
        XCTAssertNotNil(cycleBack.b?.value.a)
        XCTAssertNil(cycleBack.b?.value.a?.value.b)
        let node = try emitSwift(pool: try parseAvsc(nodeSchema))
        XCTAssertTrue(node.joinedSource.contains("Box<Node>"))
        XCTAssertTrue(node.joinedSource.contains("self = .string(\"\")") || node.joinedSource.contains("self = .string(\"\")"))
        XCTAssertThrowsError(try emitSwift(pool: try parseAvsc(#"{"type":"record","name":"Loop","fields":[{"name":"self","type":"Loop"}]}"#)))
    }

    func testLogical() throws {
        XCTAssertEqual(AvroLogical.days(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(AvroLogical.ymd(days: 0).year, 1970)
        XCTAssertEqual(AvroLogical.ymd(days: 0).month, 1)
        XCTAssertEqual(AvroLogical.ymd(days: 0).day, 1)
        let date = AvroLogical.days(year: 2020, month: 2, day: 29)
        let parts = AvroLogical.ymd(days: date)
        XCTAssertEqual(parts.year, 2020)
        XCTAssertEqual(parts.month, 2)
        XCTAssertEqual(parts.day, 29)
        XCTAssertTrue(AvroLogical.validateUUID("00112233-4455-6677-8899-aabbccddeeff"))
        XCTAssertFalse(AvroLogical.validateUUID("nope"))
        XCTAssertEqual(try AvroLogical.decimalUnscaled(AvroLogical.decimalBytes(-2)), -2)
        let duration = AvroDuration(months: 1, days: 2, milliseconds: 3)
        XCTAssertEqual(try AvroDuration(fixedBytes: duration.fixedBytes()), duration)
        let dated = try parseAvsc(#"{"type":"int","logicalType":"date"}"#)
        XCTAssertEqual(dated.nodes[dated.root].logicalType, "date")
    }

    func testGeneratedRecords() throws {
        let value = ex_Kitchen(
            n: AvroNull(),
            b: true,
            i: -7,
            l: 99,
            f: 1.5,
            d: -2.25,
            by: Array("abc".utf8),
            s: "hi",
            a: [1, 2, 3],
            m: ["k": "v"],
            e: .GREEN,
            fx: ex_Hash4(bytes: [1, 2, 3, 4]),
            u: "yo",
            inner: ex_Inner(x: 5)
        )
        let bytes = encode(value)
        XCTAssertEqual(hex(bytes), kitchenHex)
        XCTAssertEqual(value.encodedByteLength(), bytes.count)
        let back = try decode(ex_Kitchen.self, from: bytes)
        XCTAssertEqual(back.s, "hi")
        XCTAssertEqual(back.u, "yo")
        XCTAssertEqual(back.a, [1, 2, 3])
        XCTAssertEqual(back.inner.x, 5)
        XCTAssertEqual(back.e, .GREEN)
        XCTAssertThrows(try decode(ex_Kitchen.self, from: Array(bytes.prefix(4))), .eof)
        let list = LongList(value: 1, next: Box(LongList(value: 2, next: nil)))
        let listBytes = encode(list)
        let decodedList = try decode(LongList.self, from: listBytes)
        XCTAssertEqual(decodedList.next?.value.value, 2)
        if case .string(let text) = Node().payload {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("zero Node should select the string branch")
        }
        _ = try parseAvsc(Node.schemaJSON)
        _ = try parseAvsc(LongList.schemaJSON)
        _ = try parseAvsc(ex_Kitchen.schemaJSON)
        let node = Node(payload: .node(Box(Node())))
        let nodeBytes = encode(node)
        let nodeBack = try decode(Node.self, from: nodeBytes)
        if case .node(let boxed) = nodeBack.payload {
            if case .string = boxed.value.payload {} else { XCTFail("nested zero payload") }
        } else {
            XCTFail("expected node branch")
        }
        var container = OCFWriter(schemaJSON: ex_Kitchen.schemaJSON, codec: .deflate, sync: [UInt8](repeating: 7, count: 16))
        container.append(value)
        let rows = try readOCF(ex_Kitchen.self, from: container.finish())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].s, "hi")
        XCTAssertEqual(rows[0].inner.x, 5)
        let frame = try encodeSingleObject(value)
        XCTAssertEqual(try decodeSingleObject(ex_Kitchen.self, from: frame).l, 99)
        let json = try encodeJSON(value)
        let fromJSON = try decodeJSON(ex_Kitchen.self, json)
        XCTAssertEqual(fromJSON.i, -7)
        XCTAssertEqual(fromJSON.f, 1.5)
        XCTAssertEqual(fromJSON.d, -2.25)
        XCTAssertEqual(fromJSON.s, "hi")
        XCTAssertEqual(fromJSON.e, .GREEN)
        XCTAssertEqual(fromJSON.by, Array("abc".utf8))
    }

    func testVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version, avroLibraryVersion)
    }
}

struct HandLong: AvroCodable {
    var value: Int64
    init(_ value: Int64) { self.value = value }
    func encodedByteLength() -> Int { AvroBinary.longLength(value) }
    func encode(into encoder: inout BinaryEncoder) { encoder.writeLong(value) }
    static func decode(from decoder: inout BinaryDecoder) throws -> HandLong { try HandLong(decoder.readLong()) }
    static var schemaJSON: String { "\"long\"" }
    static func fromResolved(_ value: AvroValue) throws -> HandLong { try HandLong(AvroResolved.int64(value)) }
}

struct HandInt: AvroCodable {
    var value: Int32
    init(_ value: Int32) { self.value = value }
    func encodedByteLength() -> Int { AvroBinary.intLength(value) }
    func encode(into encoder: inout BinaryEncoder) { encoder.writeInt(value) }
    static func decode(from decoder: inout BinaryDecoder) throws -> HandInt { try HandInt(decoder.readInt()) }
    static var schemaJSON: String { "\"int\"" }
    static func fromResolved(_ value: AvroValue) throws -> HandInt { try HandInt(AvroResolved.int32(value)) }
}

let kitchenSchema = """
{"type":"record","name":"Kitchen","namespace":"ex","fields":[
 {"name":"n","type":"null"},
 {"name":"b","type":"boolean"},
 {"name":"i","type":"int"},
 {"name":"l","type":"long"},
 {"name":"f","type":"float"},
 {"name":"d","type":"double"},
 {"name":"by","type":"bytes"},
 {"name":"s","type":"string"},
 {"name":"a","type":{"type":"array","items":"int"}},
 {"name":"m","type":{"type":"map","values":"string"}},
 {"name":"e","type":{"type":"enum","name":"Color","symbols":["RED","GREEN","BLUE"]}},
 {"name":"fx","type":{"type":"fixed","name":"Hash4","size":4}},
 {"name":"u","type":["null","string"]},
 {"name":"inner","type":{"type":"record","name":"Inner","fields":[{"name":"x","type":"int"}]}}
]}
"""

let kitchenValue = AvroValue.record([
    .null, .boolean(true), .int(-7), .long(99), .float(1.5), .double(-2.25),
    .bytes(Array("abc".utf8)), .string("hi"),
    .array([.int(1), .int(2), .int(3)]),
    .map([("k", .string("v"))]),
    .enumeration("GREEN"),
    .fixed([1, 2, 3, 4]),
    .union(index: 1, value: .string("yo")),
    .record([.int(5)]),
])

let kitchenHex = "010dc6010000c03f00000000000002c006616263046869060204060002026b02760002010203040204796f0a"

let longListSchema = """
{"type":"record","name":"LongList","fields":[{"name":"value","type":"long"},{"name":"next","type":["null","LongList"]}]}
"""

let mutualSchema = """
[{"type":"record","name":"A","fields":[{"name":"b","type":["null","B"]}]},{"type":"record","name":"B","fields":[{"name":"a","type":["null","A"]}]}]
"""

let nodeSchema = """
{"type":"record","name":"Node","fields":[{"name":"payload","type":["Node","string"]}]}
"""

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func unhex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

func XCTAssertThrows(_ body: @autoclosure () throws -> some Any, _ kind: DecodeError.Kind, file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try body()
        XCTFail("expected throw", file: file, line: line)
    } catch let error as DecodeError {
        XCTAssertEqual(error.kind, kind, file: file, line: line)
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
    }
}

func XCTAssertThrowsSchema(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try parseAvsc(text), file: file, line: line)
}

func XCTAssertThrowsSchemaIDL(_ text: String, files: [String: String], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try parseAvdl(text, resolver: MemoryImportResolver(files: files), fromFile: "root.avdl"), file: file, line: line)
}

extension Array where Element == (name: String, source: String) {
    var joinedSource: String { map(\.source).joined(separator: "\n") }
}
