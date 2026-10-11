public let crc64AvroEmpty: UInt64 = 0xc15d213aa4d7a795

private let crc64Table: [UInt64] = {
    let poly = crc64AvroEmpty
    var table = [UInt64](repeating: 0, count: 256)
    for i in 0..<256 {
        var fp = UInt64(i)
        for _ in 0..<8 {
            let mask: UInt64 = 0 &- (fp & 1)
            fp = (fp >> 1) ^ (poly & mask)
        }
        table[i] = fp
    }
    return table
}()

public func crc64Avro(bytes: [UInt8]) -> UInt64 {
    var result = crc64AvroEmpty
    for byte in bytes {
        let index = Int((result ^ UInt64(byte)) & 0xff)
        result = (result >> 8) ^ crc64Table[index]
    }
    return result
}

public func crc64Avro(_ text: String) -> UInt64 {
    crc64Avro(bytes: Array(text.utf8))
}

public func crc64AvroLittleEndianBytes(_ value: UInt64) -> [UInt8] {
    var le = value.littleEndian
    return withUnsafeBytes(of: &le) { Array($0) }
}
