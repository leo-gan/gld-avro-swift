public let avroMaxInflateBytes = 64_194_304

public func deflateRaw(_ data: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    var offset = 0
    if data.isEmpty {
        output.append(0x01)
        output.append(0x00)
        output.append(0x00)
        output.append(0xff)
        output.append(0xff)
        return output
    }
    while offset < data.count {
        let remaining = data.count - offset
        let take = min(remaining, 65_535)
        let final = offset + take == data.count
        output.append(final ? 0x01 : 0x00)
        let length = UInt16(take)
        output.append(UInt8(length & 0xff))
        output.append(UInt8(length >> 8))
        let complement = length ^ 0xffff
        output.append(UInt8(complement & 0xff))
        output.append(UInt8(complement >> 8))
        output.append(contentsOf: data[offset..<(offset + take)])
        offset += take
    }
    return output
}

public func inflateRaw(_ data: [UInt8], maxOutput: Int = avroMaxInflateBytes) throws -> [UInt8] {
    var reader = BitReader(data)
    var output: [UInt8] = []
    output.reserveCapacity(min(data.count * 2, 4096))
    var final = false
    while !final {
        final = try reader.bit() == 1
        let type = try reader.bits(2)
        switch type {
        case 0:
            try inflateStored(&reader, into: &output, maxOutput: maxOutput)
        case 1:
            try inflateCodes(fixedLiteral, fixedDistance, &reader, into: &output, maxOutput: maxOutput)
        case 2:
            let (literal, distance) = try dynamicTrees(&reader)
            try inflateCodes(literal, distance, &reader, into: &output, maxOutput: maxOutput)
        default:
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "bad block type")
        }
    }
    return output
}

struct BitReader {
    var data: [UInt8]
    var byte: Int = 0
    var bitIndex: Int = 0

    init(_ data: [UInt8]) { self.data = data }

    mutating func bit() throws -> Int {
        guard byte < data.count else {
            throw DecodeError(kind: .deflate, offset: byte, message: "truncated")
        }
        let value = (Int(data[byte]) >> bitIndex) & 1
        bitIndex += 1
        if bitIndex == 8 {
            bitIndex = 0
            byte += 1
        }
        return value
    }

    mutating func bits(_ count: Int) throws -> Int {
        var value = 0
        for shift in 0..<count {
            value |= try bit() << shift
        }
        return value
    }

    mutating func align() {
        if bitIndex != 0 {
            bitIndex = 0
            byte += 1
        }
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        align()
        guard byte + count <= data.count else {
            throw DecodeError(kind: .deflate, offset: byte, message: "truncated stored")
        }
        let slice = data[byte..<(byte + count)]
        byte += count
        return slice
    }
}

struct Huffman {
    var maxLength: Int
    var table: [[Int]]

    func decode(_ reader: inout BitReader) throws -> Int {
        if maxLength == 0 {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "empty huffman")
        }
        var code = 0
        for length in 1...maxLength {
            code = (code << 1) | (try reader.bit())
            let symbol = table[length][code]
            if symbol >= 0 {
                return symbol
            }
        }
        throw DecodeError(kind: .deflate, offset: reader.byte, message: "bad huffman code")
    }
}

func buildHuffman(_ lengths: [Int]) throws -> Huffman {
    var counts = [Int](repeating: 0, count: 16)
    for length in lengths {
        if length < 0 || length > 15 {
            throw DecodeError(kind: .deflate, offset: 0, message: "bad code length")
        }
        counts[length] += 1
    }
    counts[0] = 0
    var next = [Int](repeating: 0, count: 16)
    var code = 0
    for bits in 1...15 {
        code = (code + counts[bits - 1]) << 1
        next[bits] = code
    }
    var table = Array(repeating: [Int](), count: 16)
    var maxLength = 1
    for length in lengths where length > maxLength { maxLength = length }
    if maxLength < 1 { maxLength = 1 }
    for length in 1...maxLength {
        table[length] = [Int](repeating: -1, count: 1 << length)
    }
    var used = 0
    for symbol in 0..<lengths.count {
        let length = lengths[symbol]
        if length == 0 { continue }
        let assigned = next[length]
        if assigned >= (1 << length) {
            throw DecodeError(kind: .deflate, offset: 0, message: "oversubscribed huffman")
        }
        next[length] = assigned + 1
        table[length][assigned] = symbol
        used += 1
        if length > maxLength { maxLength = length }
    }
    if used == 0 { maxLength = 0 }
    return Huffman(maxLength: maxLength, table: table)
}

let fixedLiteral: Huffman = {
    var lengths = [Int](repeating: 0, count: 288)
    for index in 0...143 { lengths[index] = 8 }
    for index in 144...255 { lengths[index] = 9 }
    for index in 256...279 { lengths[index] = 7 }
    for index in 280...287 { lengths[index] = 8 }
    return try! buildHuffman(lengths)
}()

let fixedDistance: Huffman = {
    try! buildHuffman([Int](repeating: 5, count: 32))
}()

let lengthBase = [
    3, 4, 5, 6, 7, 8, 9, 10,
    11, 13, 15, 17,
    19, 23, 27, 31,
    35, 43, 51, 59,
    67, 83, 99, 115,
    131, 163, 195, 227,
    258,
]
let lengthExtra = [
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1,
    2, 2, 2, 2,
    3, 3, 3, 3,
    4, 4, 4, 4,
    5, 5, 5, 5,
    0,
]
let distanceBase = [
    1, 2, 3, 4,
    5, 7,
    9, 13,
    17, 25,
    33, 49,
    65, 97,
    129, 193,
    257, 385,
    513, 769,
    1025, 1537,
    2049, 3073,
    4097, 6145,
    8193, 12289,
    16385, 24577,
]
let distanceExtra = [
    0, 0, 0, 0,
    1, 1,
    2, 2,
    3, 3,
    4, 4,
    5, 5,
    6, 6,
    7, 7,
    8, 8,
    9, 9,
    10, 10,
    11, 11,
    12, 12,
    13, 13,
]

func inflateStored(_ reader: inout BitReader, into output: inout [UInt8], maxOutput: Int) throws {
    reader.align()
    let raw = try reader.bytes(4)
    let bytes = Array(raw)
    let length = Int(bytes[0]) | (Int(bytes[1]) << 8)
    let complement = Int(bytes[2]) | (Int(bytes[3]) << 8)
    if length ^ 0xffff != complement {
        throw DecodeError(kind: .deflate, offset: reader.byte, message: "stored length")
    }
    let payload = try reader.bytes(length)
    guard output.count + length <= maxOutput else {
        throw DecodeError(kind: .deflate, offset: reader.byte, message: "inflate cap")
    }
    output.append(contentsOf: payload)
}

func dynamicTrees(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
    let literalCount = try reader.bits(5) + 257
    let distanceCount = try reader.bits(5) + 1
    let codeCount = try reader.bits(4) + 4
    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var codeLengths = [Int](repeating: 0, count: 19)
    for index in 0..<codeCount {
        codeLengths[order[index]] = try reader.bits(3)
    }
    let codeTree = try buildHuffman(codeLengths)
    var lengths: [Int] = []
    lengths.reserveCapacity(literalCount + distanceCount)
    while lengths.count < literalCount + distanceCount {
        let symbol = try codeTree.decode(&reader)
        if symbol < 16 {
            lengths.append(symbol)
        } else if symbol == 16 {
            guard let previous = lengths.last else {
                throw DecodeError(kind: .deflate, offset: reader.byte, message: "repeat")
            }
            let times = try reader.bits(2) + 3
            for _ in 0..<times { lengths.append(previous) }
        } else if symbol == 17 {
            let times = try reader.bits(3) + 3
            for _ in 0..<times { lengths.append(0) }
        } else if symbol == 18 {
            let times = try reader.bits(7) + 11
            for _ in 0..<times { lengths.append(0) }
        } else {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "code length")
        }
        if lengths.count > literalCount + distanceCount {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "too many lengths")
        }
    }
    let literal = try buildHuffman(Array(lengths[0..<literalCount]))
    let distance = try buildHuffman(Array(lengths[literalCount...]))
    return (literal, distance)
}

func inflateCodes(
    _ literal: Huffman,
    _ distance: Huffman,
    _ reader: inout BitReader,
    into output: inout [UInt8],
    maxOutput: Int
) throws {
    while true {
        let symbol = try literal.decode(&reader)
        if symbol < 256 {
            guard output.count < maxOutput else {
                throw DecodeError(kind: .deflate, offset: reader.byte, message: "inflate cap")
            }
            output.append(UInt8(symbol))
            continue
        }
        if symbol == 256 { return }
        if symbol > 285 {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "bad length")
        }
        let lengthIndex = symbol - 257
        var length = lengthBase[lengthIndex]
        let extra = lengthExtra[lengthIndex]
        if extra > 0 { length += try reader.bits(extra) }
        let distanceSymbol = try distance.decode(&reader)
        guard distanceSymbol < distanceBase.count else {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "bad distance")
        }
        var distanceValue = distanceBase[distanceSymbol]
        let distanceBits = distanceExtra[distanceSymbol]
        if distanceBits > 0 { distanceValue += try reader.bits(distanceBits) }
        if distanceValue == 0 || distanceValue > output.count {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "distance")
        }
        guard output.count + length <= maxOutput else {
            throw DecodeError(kind: .deflate, offset: reader.byte, message: "inflate cap")
        }
        for _ in 0..<length {
            output.append(output[output.count - distanceValue])
        }
    }
}
