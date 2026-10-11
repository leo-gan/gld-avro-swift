import Avro
import Dispatch

let schemaText = """
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

let value = AvroValue.record([
    .null,
    .boolean(true),
    .int(-7),
    .long(99),
    .float(1.5),
    .double(-2.25),
    .bytes(Array("abc".utf8)),
    .string("hi"),
    .array([.int(1), .int(2), .int(3)]),
    .map([("k", .string("v"))]),
    .enumeration("GREEN"),
    .fixed([1, 2, 3, 4]),
    .union(index: 1, value: .string("yo")),
    .record([.int(5)]),
])

@main
struct Bench {
    static func main() throws {
        let pool = try parseAvsc(schemaText)
        let encoded = try encodeGeneric(value, pool: pool)
        let iterations = 20_000
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations {
            let bytes = try encodeGeneric(value, pool: pool)
            sink &+= bytes.count
        }
        let encodeElapsed = DispatchTime.now().uptimeNanoseconds - encodeStart
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let decoded = try decodeGeneric(encoded, pool: pool)
            if case .record(let fields) = decoded { sink &+= fields.count }
        }
        let decodeElapsed = DispatchTime.now().uptimeNanoseconds - decodeStart
        let encodeNs = Double(encodeElapsed) / Double(iterations)
        let decodeNs = Double(decodeElapsed) / Double(iterations)
        let wireStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            var encoder = BinaryEncoder(reserving: 64)
            encodeKitchen(&encoder)
            sink &+= encoder.bytes.count
        }
        let wireEncode = DispatchTime.now().uptimeNanoseconds - wireStart
        var sample = BinaryEncoder(reserving: 64)
        encodeKitchen(&sample)
        let wireBytes = sample.bytes
        let wireDecodeStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            var decoder = BinaryDecoder(wireBytes)
            sink &+= try decodeKitchen(&decoder)
        }
        let wireDecode = DispatchTime.now().uptimeNanoseconds - wireDecodeStart
        print(String(format: "generic encode %.1f ns/op", encodeNs))
        print(String(format: "generic decode %.1f ns/op", decodeNs))
        print(String(format: "direct encode %.1f ns/op", Double(wireEncode) / Double(iterations)))
        print(String(format: "direct decode %.1f ns/op", Double(wireDecode) / Double(iterations)))
        print("payload \(encoded.count) bytes sink \(sink)")
    }
}

func encodeKitchen(_ encoder: inout BinaryEncoder) {
    encoder.writeBool(true)
    encoder.writeInt(-7)
    encoder.writeLong(99)
    encoder.writeFloat(1.5)
    encoder.writeDouble(-2.25)
    encoder.writeBytes(Array("abc".utf8))
    encoder.writeString("hi")
    encoder.writeLong(3)
    encoder.writeInt(1)
    encoder.writeInt(2)
    encoder.writeInt(3)
    encoder.writeLong(0)
    encoder.writeLong(1)
    encoder.writeString("k")
    encoder.writeString("v")
    encoder.writeLong(0)
    encoder.writeInt(1)
    encoder.writeFixed([1, 2, 3, 4])
    encoder.writeLong(1)
    encoder.writeString("yo")
    encoder.writeInt(5)
}

func decodeKitchen(_ decoder: inout BinaryDecoder) throws -> Int {
    var n = 0
    if try decoder.readBool() { n += 1 }
    n += Int(try decoder.readInt())
    n += Int(try decoder.readLong())
    _ = try decoder.readFloat()
    _ = try decoder.readDouble()
    n += try decoder.readBytes().count
    n += try decoder.readString().utf8.count
    let count = try decoder.readLong()
    for _ in 0..<count { n += Int(try decoder.readInt()) }
    _ = try decoder.readLong()
    let maps = try decoder.readLong()
    for _ in 0..<maps {
        n += try decoder.readString().utf8.count
        n += try decoder.readString().utf8.count
    }
    _ = try decoder.readLong()
    n += Int(try decoder.readInt())
    n += try decoder.readFixed(4).count
    _ = try decoder.readLong()
    n += try decoder.readString().utf8.count
    n += Int(try decoder.readInt())
    return n
}
