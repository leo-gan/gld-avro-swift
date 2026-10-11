import Avro

@main
struct EncodeRecord {
    static func main() throws {
        let schema = """
        {"type":"record","name":"Greeting","fields":[{"name":"text","type":"string"},{"name":"n","type":"int"}]}
        """
        let pool = try parseAvsc(schema)
        let value = AvroValue.record([.string("hello"), .int(3)])
        let bytes = try encodeGeneric(value, pool: pool)
        let back = try decodeGeneric(bytes, pool: pool)
        guard back == value else {
            fatalError("round trip failed")
        }
        print("encoded \(bytes.count) bytes")
    }
}
